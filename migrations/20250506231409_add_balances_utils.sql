-- +goose Up
-- +goose StatementBegin

-- create a function that will be called by the trigger
create or replace function utils.update_account_balance()
    returns trigger as $$
declare
    v_debit_account_previous_balance  bigint;
    v_debit_account_internal_type     text; -- CORRECTED: Was data.account_internal_type
    v_delta_debit                     bigint;

    v_credit_account_previous_balance bigint;
    v_credit_account_internal_type    text; -- CORRECTED: Was data.account_internal_type
    v_delta_credit                    bigint;

    v_ledger_id                       bigint;
begin
    -- ledger ID is already in the transaction
    v_ledger_id := NEW.ledger_id;

    -- Process DEBIT side
    -- Get previous balance and internal type for the DEBIT account
    select balance into v_debit_account_previous_balance
    from data.balances
    where account_id = new.debit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_debit_account_internal_type
    from data.accounts where id = new.debit_account_id;

    if v_debit_account_previous_balance is null then
        v_debit_account_previous_balance := 0;
    end if;

    if v_debit_account_internal_type is null then
        raise exception 'internal_type not found for debit account %', new.debit_account_id;
    end if;

    -- Calculate delta for DEBIT account
    if v_debit_account_internal_type = 'asset_like' then
        v_delta_debit := new.amount; -- debit to asset increases balance
    elsif v_debit_account_internal_type = 'liability_like' then
        v_delta_debit := -new.amount; -- debit to liability/equity decreases balance
    else
        raise exception 'unknown internal_type % for debit account %', v_debit_account_internal_type, new.debit_account_id;
    end if;

    -- Insert new balance for DEBIT account
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.debit_account_id, new.id, v_ledger_id, v_debit_account_previous_balance, v_delta_debit,
            v_debit_account_previous_balance + v_delta_debit, 'transaction_insert');

    -- Process CREDIT side
    -- Get previous balance and internal type for the CREDIT account
    select balance into v_credit_account_previous_balance
    from data.balances
    where account_id = new.credit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_credit_account_internal_type
    from data.accounts where id = new.credit_account_id;

    if v_credit_account_previous_balance is null then
        v_credit_account_previous_balance := 0;
    end if;

    if v_credit_account_internal_type is null then
        raise exception 'internal_type not found for credit account %', new.credit_account_id;
    end if;

    -- Calculate delta for CREDIT account
    if v_credit_account_internal_type = 'asset_like' then
        v_delta_credit := -new.amount; -- credit to asset decreases balance
    elsif v_credit_account_internal_type = 'liability_like' then
        v_delta_credit := new.amount; -- credit to liability/equity increases balance
    else
        raise exception 'unknown internal_type % for credit account %', v_credit_account_internal_type, new.credit_account_id;
    end if;

    -- Insert new balance for CREDIT account
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.credit_account_id, new.id, v_ledger_id, v_credit_account_previous_balance, v_delta_credit,
            v_credit_account_previous_balance + v_delta_credit, 'transaction_insert');

    return NEW;
end;
$$ language plpgsql security definer;

-- function to handle balance updates when a transaction is deleted
create or replace function utils.handle_transaction_delete_balance()
    returns trigger as
$$
declare
    v_old_debit_account_previous_balance  bigint;
    v_old_debit_account_internal_type     text;
    v_delta_reversal_debit                bigint;

    v_old_credit_account_previous_balance bigint;
    v_old_credit_account_internal_type    text;
    v_delta_reversal_credit               bigint;
begin
    -- REVERSAL FOR OLD DEBIT ACCOUNT
    -- get previous balance and internal type for the OLD DEBIT account
    select balance into v_old_debit_account_previous_balance
    from data.balances
    where account_id = old.debit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_old_debit_account_internal_type
    from data.accounts where id = old.debit_account_id;

    if v_old_debit_account_previous_balance is null then
        v_old_debit_account_previous_balance := 0;
    end if;

    if v_old_debit_account_internal_type is null then
        raise exception 'internal_type not found for old debit account %', old.debit_account_id;
    end if;

    -- calculate reversal delta for OLD DEBIT account
    if v_old_debit_account_internal_type = 'asset_like' then
        v_delta_reversal_debit := -old.amount; -- reversing a debit to asset decreases balance
    elsif v_old_debit_account_internal_type = 'liability_like' then
        v_delta_reversal_debit := old.amount;  -- reversing a debit to liability/equity increases balance
    else
        raise exception 'unknown internal_type % for old debit account %', v_old_debit_account_internal_type, old.debit_account_id;
    end if;

    -- insert balance entry for OLD DEBIT account reversal
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.debit_account_id, old.id, old.ledger_id, v_old_debit_account_previous_balance, v_delta_reversal_debit,
            v_old_debit_account_previous_balance + v_delta_reversal_debit, 'transaction_delete');

    -- REVERSAL FOR OLD CREDIT ACCOUNT
    -- get previous balance and internal type for the OLD CREDIT account
    select balance into v_old_credit_account_previous_balance
    from data.balances
    where account_id = old.credit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_old_credit_account_internal_type
    from data.accounts where id = old.credit_account_id;

    if v_old_credit_account_previous_balance is null then
        v_old_credit_account_previous_balance := 0;
    end if;

    if v_old_credit_account_internal_type is null then
        raise exception 'internal_type not found for old credit account %', old.credit_account_id;
    end if;

    -- calculate reversal delta for OLD CREDIT account
    if v_old_credit_account_internal_type = 'asset_like' then
        v_delta_reversal_credit := old.amount;  -- reversing a credit to asset increases balance
    elsif v_old_credit_account_internal_type = 'liability_like' then
        v_delta_reversal_credit := -old.amount; -- reversing a credit to liability/equity decreases balance
    else
        raise exception 'unknown internal_type % for old credit account %', v_old_credit_account_internal_type, old.credit_account_id;
    end if;

    -- insert balance entry for OLD CREDIT account reversal
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.credit_account_id, old.id, old.ledger_id, v_old_credit_account_previous_balance, v_delta_reversal_credit,
            v_old_credit_account_previous_balance + v_delta_reversal_credit, 'transaction_delete');

    return old; -- for AFTER DELETE, return value is ignored but OLD is conventional
end;
$$ language plpgsql security definer;

-- function to handle balance updates when a transaction is updated
create or replace function utils.handle_transaction_update_balance()
    returns trigger as
$$
declare
    -- variables for OLD transaction reversal
    v_old_debit_account_previous_balance  bigint;
    v_old_debit_account_internal_type     text;
    v_delta_reversal_old_debit            bigint;

    v_old_credit_account_previous_balance bigint;
    v_old_credit_account_internal_type    text;
    v_delta_reversal_old_credit           bigint;

    -- variables for NEW transaction application
    v_new_debit_account_previous_balance  bigint;
    v_new_debit_account_internal_type     text;
    v_delta_application_new_debit         bigint;

    v_new_credit_account_previous_balance bigint;
    v_new_credit_account_internal_type    text;
    v_delta_application_new_credit        bigint;
begin
    -- STEP 1: REVERSE THE EFFECTS OF THE OLD TRANSACTION VALUES

    -- REVERSAL FOR OLD DEBIT ACCOUNT
    select balance into v_old_debit_account_previous_balance
    from data.balances where account_id = old.debit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_old_debit_account_internal_type
    from data.accounts where id = old.debit_account_id;
    if v_old_debit_account_previous_balance is null then v_old_debit_account_previous_balance := 0; end if;
    if v_old_debit_account_internal_type is null then raise exception 'internal_type not found for old debit account %', old.debit_account_id; end if;

    if v_old_debit_account_internal_type = 'asset_like' then v_delta_reversal_old_debit := -old.amount;
    elsif v_old_debit_account_internal_type = 'liability_like' then v_delta_reversal_old_debit := old.amount;
    else raise exception 'unknown internal_type % for old debit account %', v_old_debit_account_internal_type, old.debit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.debit_account_id, old.id, old.ledger_id, v_old_debit_account_previous_balance, v_delta_reversal_old_debit,
            v_old_debit_account_previous_balance + v_delta_reversal_old_debit, 'transaction_update_reversal');

    -- REVERSAL FOR OLD CREDIT ACCOUNT
    select balance into v_old_credit_account_previous_balance
    from data.balances where account_id = old.credit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_old_credit_account_internal_type
    from data.accounts where id = old.credit_account_id;
    if v_old_credit_account_previous_balance is null then v_old_credit_account_previous_balance := 0; end if;
    if v_old_credit_account_internal_type is null then raise exception 'internal_type not found for old credit account %', old.credit_account_id; end if;

    if v_old_credit_account_internal_type = 'asset_like' then v_delta_reversal_old_credit := old.amount;
    elsif v_old_credit_account_internal_type = 'liability_like' then v_delta_reversal_old_credit := -old.amount;
    else raise exception 'unknown internal_type % for old credit account %', v_old_credit_account_internal_type, old.credit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.credit_account_id, old.id, old.ledger_id, v_old_credit_account_previous_balance, v_delta_reversal_old_credit,
            v_old_credit_account_previous_balance + v_delta_reversal_old_credit, 'transaction_update_reversal');

    -- STEP 2: APPLY THE EFFECTS OF THE NEW TRANSACTION VALUES

    -- APPLICATION FOR NEW DEBIT ACCOUNT
    -- Previous balance for the NEW debit account is the latest balance *after* any reversal involving this account.
    select balance into v_new_debit_account_previous_balance
    from data.balances where account_id = new.debit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_new_debit_account_internal_type
    from data.accounts where id = new.debit_account_id;
    if v_new_debit_account_previous_balance is null then v_new_debit_account_previous_balance := 0; end if; -- Should not be null if reversal happened correctly
    if v_new_debit_account_internal_type is null then raise exception 'internal_type not found for new debit account %', new.debit_account_id; end if;

    if v_new_debit_account_internal_type = 'asset_like' then v_delta_application_new_debit := new.amount;
    elsif v_new_debit_account_internal_type = 'liability_like' then v_delta_application_new_debit := -new.amount;
    else raise exception 'unknown internal_type % for new debit account %', v_new_debit_account_internal_type, new.debit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.debit_account_id, new.id, new.ledger_id, v_new_debit_account_previous_balance, v_delta_application_new_debit,
            v_new_debit_account_previous_balance + v_delta_application_new_debit, 'transaction_update_application');

    -- APPLICATION FOR NEW CREDIT ACCOUNT
    -- Previous balance for the NEW credit account is the latest balance *after* any reversal involving this account.
    select balance into v_new_credit_account_previous_balance
    from data.balances where account_id = new.credit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_new_credit_account_internal_type
    from data.accounts where id = new.credit_account_id;
    if v_new_credit_account_previous_balance is null then v_new_credit_account_previous_balance := 0; end if; -- Should not be null if reversal happened correctly
    if v_new_credit_account_internal_type is null then raise exception 'internal_type not found for new credit account %', new.credit_account_id; end if;

    if v_new_credit_account_internal_type = 'asset_like' then v_delta_application_new_credit := -new.amount;
    elsif v_new_credit_account_internal_type = 'liability_like' then v_delta_application_new_credit := new.amount;
    else raise exception 'unknown internal_type % for new credit account %', v_new_credit_account_internal_type, new.credit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.credit_account_id, new.id, new.ledger_id, v_new_credit_account_previous_balance, v_delta_application_new_credit,
            v_new_credit_account_previous_balance + v_delta_application_new_credit, 'transaction_update_application');

    return new;
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
    p_ledger_id integer,
    p_account_id integer
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
        raise exception 'Account not found or does not belong to the specified ledger';
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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the function to handle transaction updates
drop function if exists utils.handle_transaction_update_balance();

-- drop the function to handle transaction deletes
drop function if exists utils.handle_transaction_delete_balance();

-- drop the function to get budget status
drop function if exists utils.get_budget_status(integer);

-- drop the function to get account balance
drop function if exists utils.get_account_balance(integer, integer);

-- drop the function to get account transactions
drop function if exists utils.get_account_transactions(integer);

-- drop the trigger function
drop function if exists utils.update_account_balance();

-- +goose StatementEnd
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
