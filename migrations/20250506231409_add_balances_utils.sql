-- +goose Up
-- +goose StatementBegin

-- simple function to update account balances
create or replace function utils.update_account_balance()
    returns trigger as $$
declare
    v_debit_prev_balance bigint := 0;
    v_credit_prev_balance bigint := 0;
    v_debit_delta bigint;
    v_credit_delta bigint;
    v_debit_type text;
    v_credit_type text;
begin
    -- get previous balances (0 if none exist)
    select coalesce(new_balance, 0) into v_debit_prev_balance
    from data.balances 
    where account_id = NEW.debit_account_id 
    order by created_at desc, id desc 
    limit 1;
    
    select coalesce(new_balance, 0) into v_credit_prev_balance
    from data.balances 
    where account_id = NEW.credit_account_id 
    order by created_at desc, id desc 
    limit 1;
    
    -- get account types
    select internal_type into v_debit_type 
    from data.accounts 
    where id = NEW.debit_account_id;
    
    select internal_type into v_credit_type 
    from data.accounts 
    where id = NEW.credit_account_id;
    
    -- calculate deltas based on account type
    if v_debit_type = 'asset_like' then
        v_debit_delta := NEW.amount;
    else
        v_debit_delta := -NEW.amount;
    end if;
    
    if v_credit_type = 'asset_like' then
        v_credit_delta := -NEW.amount;
    else
        v_credit_delta := NEW.amount;
    end if;
    
    -- insert balance records
    insert into data.balances (
        account_id, transaction_id, ledger_id, previous_balance, delta, new_balance, operation_type, user_data
    )
    values 
        (NEW.debit_account_id, NEW.id, NEW.ledger_id, COALESCE(v_debit_prev_balance, 0), v_debit_delta, COALESCE(v_debit_prev_balance, 0) + v_debit_delta, 'transaction_insert', NEW.user_data),
        (NEW.credit_account_id, NEW.id, NEW.ledger_id, COALESCE(v_credit_prev_balance, 0), v_credit_delta, COALESCE(v_credit_prev_balance, 0) + v_credit_delta, 'transaction_insert', NEW.user_data);
    
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
            b.new_balance as balance
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
) returns bigint as $$
declare
    v_balance bigint;
begin
    -- validate account belongs to ledger
    if not exists (
        select 1 from data.accounts 
        where id = p_account_id and ledger_id = p_ledger_id
    ) then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;

    -- get latest balance from balances table
    select coalesce(new_balance, 0) into v_balance
    from data.balances 
    where account_id = p_account_id 
    order by created_at desc, id desc 
    limit 1;

    return coalesce(v_balance, 0);
end;
$$ language plpgsql stable security definer;

-- function to get the latest balance from the balances table
create or replace function utils.get_latest_account_balance(
    p_account_id integer
) returns bigint as $$
declare
    v_balance bigint;
begin
    select new_balance into v_balance
      from data.balances
     where account_id = p_account_id
     order by created_at desc, id desc
     limit 1;
    
    return coalesce(v_balance, 0);
end;
$$ language plpgsql stable;

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


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the utility functions
drop function if exists utils.get_budget_status(text, text);
drop function if exists utils.get_account_transactions(text, text);
drop function if exists utils.get_account_balance(bigint, bigint);
drop function if exists utils.get_latest_account_balance(integer);
drop function if exists utils.update_account_balance();

-- +goose StatementEnd
