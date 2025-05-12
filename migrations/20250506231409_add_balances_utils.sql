-- +goose Up
-- +goose StatementBegin

-- create a function that will be called by the trigger
create or replace function utils.update_account_balance()
    returns trigger as $$
declare
    v_accounts_info record;
    v_ledger_id bigint := NEW.ledger_id;
    v_user_data text := utils.get_user();
    v_debit_delta bigint;
    v_credit_delta bigint;
begin
    -- Get account information and previous balances in a single query
    -- This reduces database roundtrips even further
    with account_data as (
        select 
            d.id as debit_id, d.internal_type as debit_type,
            c.id as credit_id, c.internal_type as credit_type
        from 
            data.accounts d
        cross join 
            data.accounts c
        where 
            d.id = NEW.debit_account_id and
            c.id = NEW.credit_account_id
    ),
    balance_data as (
        select 
            account_id, 
            balance
        from (
            select 
                account_id, 
                balance,
                row_number() over (partition by account_id order by created_at desc, id desc) as rn
            from 
                data.balances
            where 
                account_id in (NEW.debit_account_id, NEW.credit_account_id)
        ) ranked
        where 
            rn = 1
    )
    select 
        ad.debit_type, ad.credit_type,
        coalesce((select balance from balance_data where account_id = NEW.debit_account_id), 0) as debit_balance,
        coalesce((select balance from balance_data where account_id = NEW.credit_account_id), 0) as credit_balance
    into v_accounts_info
    from account_data ad;

    -- Validate account types
    if v_accounts_info.debit_type is null then
        raise exception 'internal_type not found for debit account %', NEW.debit_account_id;
    end if;

    if v_accounts_info.credit_type is null then
        raise exception 'internal_type not found for credit account %', NEW.credit_account_id;
    end if;

    -- Calculate deltas based on account types
    if v_accounts_info.debit_type = 'asset_like' then
        v_debit_delta := NEW.amount;
    elsif v_accounts_info.debit_type = 'liability_like' then
        v_debit_delta := -NEW.amount;
    else
        raise exception 'unknown internal_type % for debit account %', 
                        v_accounts_info.debit_type, NEW.debit_account_id;
    end if;

    if v_accounts_info.credit_type = 'asset_like' then
        v_credit_delta := -NEW.amount;
    elsif v_accounts_info.credit_type = 'liability_like' then
        v_credit_delta := NEW.amount;
    else
        raise exception 'unknown internal_type % for credit account %', 
                        v_accounts_info.credit_type, NEW.credit_account_id;
    end if;

    -- Insert new balances for both accounts in a single transaction
    insert into data.balances (
        account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type, user_data
    )
    values 
    (
        NEW.debit_account_id, NEW.id, v_ledger_id, 
        v_accounts_info.debit_balance, v_debit_delta,
        v_accounts_info.debit_balance + v_debit_delta, 
        'transaction_insert', v_user_data
    ),
    (
        NEW.credit_account_id, NEW.id, v_ledger_id, 
        v_accounts_info.credit_balance, v_credit_delta,
        v_accounts_info.credit_balance + v_credit_delta, 
        'transaction_insert', v_user_data
    );

    return NEW;
end;
$$ language plpgsql security definer;



create or replace function utils.get_account_transactions(
    p_account_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint,
    balance bigint
) as $$
declare
    v_account_id bigint;
    v_ledger_id bigint;
    v_internal_type text;
begin
    -- Resolve the account UUID to its internal ID and validate ownership in one query
    select a.id, a.ledger_id, a.internal_type 
    into v_account_id, v_ledger_id, v_internal_type
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = p_user_data;
    
    -- Check if account exists and belongs to the user
    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user', p_account_uuid;
    end if;

    -- Return account transactions with the account's internal type determining display
    -- Using a more efficient CTE structure
    return query
    with transaction_data as (
        -- Get all transactions involving this account
        select
            t.id as transaction_id,
            t.date,
            t.description,
            t.amount,
            t.created_at,
            -- Determine if this account was debited or credited
            case 
                when t.debit_account_id = v_account_id then 'debited'
                else 'credited' 
            end as account_role,
            -- Get the other account involved in the transaction
            case 
                when t.debit_account_id = v_account_id then t.credit_account_id
                else t.debit_account_id 
            end as other_account_id
        from 
            data.transactions t
        where 
            (t.debit_account_id = v_account_id or t.credit_account_id = v_account_id)
            and t.deleted_at is null
    ),
    other_accounts as (
        -- Get names of the other accounts involved in transactions
        select 
            a.id,
            a.name
        from 
            data.accounts a
        where 
            a.id in (select other_account_id from transaction_data)
    ),
    balance_data as (
        -- Get balance information for each transaction
        select 
            b.transaction_id,
            b.balance
        from 
            data.balances b
        where 
            b.account_id = v_account_id
            and b.transaction_id in (select transaction_id from transaction_data)
    )
    
    -- Combine all data and format for display
    select
        td.date,
        oa.name as category,
        td.description,
        -- Determine transaction type based on account's internal type and role in transaction
        case 
            when v_internal_type = 'asset_like' and td.account_role = 'debited' then 'inflow'
            when v_internal_type = 'asset_like' and td.account_role = 'credited' then 'outflow'
            when v_internal_type = 'liability_like' and td.account_role = 'debited' then 'outflow'
            when v_internal_type = 'liability_like' and td.account_role = 'credited' then 'inflow'
        end as type,
        td.amount,
        bd.balance
    from 
        transaction_data td
    join 
        other_accounts oa on td.other_account_id = oa.id
    left join 
        balance_data bd on td.transaction_id = bd.transaction_id
    order by 
        td.date desc, 
        td.created_at desc;
end;
$$ language plpgsql stable security definer;

create or replace function utils.get_account_balance(
    p_ledger_id bigint,
    p_account_id bigint
) returns numeric as $$
declare
    v_internal_type text;
    v_balance numeric;
    v_latest_balance bigint;
    v_latest_balance_ts timestamptz;
begin
    -- Get the internal type of the account (asset_like or liability_like)
    select internal_type into v_internal_type
      from data.accounts
     where id = p_account_id and ledger_id = p_ledger_id;

    if v_internal_type is null then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;

    -- First try to get the latest balance from the balances table
    -- This is much faster than recalculating from all transactions
    select balance, created_at into v_latest_balance, v_latest_balance_ts
      from data.balances
     where account_id = p_account_id
     order by created_at desc, id desc
     limit 1;
    
    if v_latest_balance is not null then
        -- Check if there are any transactions after the latest balance timestamp
        -- If not, we can just return the latest balance
        if not exists (
            select 1
              from data.transactions t
             where (t.debit_account_id = p_account_id or t.credit_account_id = p_account_id)
               and t.ledger_id = p_ledger_id
               and t.deleted_at is null
               and (t.created_at > v_latest_balance_ts or t.updated_at > v_latest_balance_ts)
        ) then
            return v_latest_balance;
        end if;
    end if;

    -- If we don't have a latest balance or there are newer transactions,
    -- calculate the balance from all transactions
    if v_internal_type = 'asset_like' then
        -- For asset-like accounts: debits increase (positive), credits decrease (negative)
        select coalesce(sum(
            case
                when debit_account_id = p_account_id then amount
                when credit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
          from data.transactions
         where ledger_id = p_ledger_id
           and (debit_account_id = p_account_id or credit_account_id = p_account_id)
           and deleted_at is null;
    else
        -- For liability-like accounts: credits increase (positive), debits decrease (negative)
        select coalesce(sum(
            case
                when credit_account_id = p_account_id then amount
                when debit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
          from data.transactions
         where ledger_id = p_ledger_id
           and (debit_account_id = p_account_id or credit_account_id = p_account_id)
           and deleted_at is null;
    end if;

    return v_balance;
end;
$$ language plpgsql stable security definer;

-- function to get the latest balance from the balances table
create or replace function utils.get_latest_account_balance(
    p_account_id integer
) returns bigint as $$
declare
    v_balance bigint;
begin
    select balance into v_balance
      from data.balances
     where account_id = p_account_id
     order by created_at desc, id desc
     limit 1;
    
    return coalesce(v_balance, 0);
end;
$$ language plpgsql;

-- create a function to get budget status for a specific ledger
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user()
)
    returns table
            (
                account_uuid text,
                account_name text,
                budgeted     decimal,
                activity     decimal,
                balance      decimal
            )
as
$$
declare
    v_ledger_id bigint;
begin
    -- Find the ledger ID and validate ownership in one query
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;
    
    -- Return budget status for all categories in the ledger
    -- Using a single query with conditional aggregation for better performance
    return query
    with categories as (
        -- Get all budget categories (equity accounts except Income)
        select 
            a.id, 
            a.uuid, 
            a.name
        from 
            data.accounts a
        where 
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type = 'equity'
            and a.name != 'Income'
            and a.name != 'Off-budget'
            and a.name != 'Unassigned'
    ),
    income_account as (
        -- Get the Income account ID for this ledger
        select 
            a.id
        from 
            data.accounts a
        where 
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type = 'equity'
            and a.name = 'Income'
        limit 1
    ),
    asset_liability_accounts as (
        -- Get all asset and liability accounts for this ledger
        select 
            a.id
        from 
            data.accounts a
        where 
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type in ('asset', 'liability')
    ),
    budget_transactions as (
        -- Transactions from Income to categories (budget allocations)
        select 
            t.credit_account_id as category_id,
            sum(t.amount) as amount
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.debit_account_id = (select id from income_account)
            and t.deleted_at is null
        group by 
            t.credit_account_id
    ),
    activity_transactions as (
        -- Transactions between categories and asset/liability accounts
        select 
            t.debit_account_id as category_id,
            -sum(t.amount) as amount -- Negative for outflows (debits to categories)
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.debit_account_id in (select id from categories)
            and t.credit_account_id in (select id from asset_liability_accounts)
            and t.deleted_at is null
        group by 
            t.debit_account_id
        
        union all
        
        select 
            t.credit_account_id as category_id,
            sum(t.amount) as amount -- Positive for inflows (credits to categories)
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.credit_account_id in (select id from categories)
            and t.debit_account_id in (select id from asset_liability_accounts)
            and t.deleted_at is null
        group by 
            t.credit_account_id
    ),
    balance_calculations as (
        -- Calculate the current balance for each category
        select 
            c.id as category_id,
            coalesce(utils.get_account_balance(v_ledger_id, c.id), 0) as balance
        from 
            categories c
    )
    
    -- Final result combining all the data
    select 
        c.uuid as account_uuid,
        c.name as account_name,
        coalesce(b.amount, 0)::decimal as budgeted,
        coalesce(sum(a.amount), 0)::decimal as activity,
        coalesce(bal.balance, 0)::decimal as balance
    from 
        categories c
    left join 
        budget_transactions b on c.id = b.category_id
    left join 
        activity_transactions a on c.id = a.category_id
    left join 
        balance_calculations bal on c.id = bal.category_id
    group by 
        c.uuid, c.name, b.amount, bal.balance
    order by 
        c.name;
end;
$$ language plpgsql stable security definer;

-- Create the API function that calls the utils function
create or replace function api.get_budget_status(
    p_ledger_uuid text
) returns table (
    account_uuid text,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
) as $$
begin
    -- Simply pass through to the utils function
    return query
    select * from utils.get_budget_status(p_ledger_uuid);
end;
$$ language plpgsql stable security invoker;

-- Grant execute permission to web user
grant execute on function api.get_budget_status(text) to pgb_web_user;

-- Create the API function for account transactions
create or replace function api.get_account_transactions(
    p_account_uuid text
) returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint,
    balance bigint
) as $$
begin
    -- Simply pass through to the utils function
    return query
    select * from utils.get_account_transactions(p_account_uuid);
end;
$$ language plpgsql stable security invoker;

-- Grant execute permission to web user
grant execute on function api.get_account_transactions(text) to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the function to handle transaction updates
drop function if exists utils.handle_transaction_update_balance();


-- drop the function to get budget status
drop function if exists utils.get_budget_status(text);

-- drop the function to get account balance
drop function if exists utils.get_account_balance(bigint, bigint);

-- drop the function to get account transactions
drop function if exists utils.get_account_transactions(text);

-- drop the trigger function
drop function if exists utils.update_account_balance();

-- drop the API functions
drop function if exists api.get_budget_status(text);
drop function if exists api.get_account_transactions(text);

-- +goose StatementEnd
