-- +goose Up
-- +goose StatementBegin
-- function to create a new account
create or replace function api.add_account(
    p_ledger_id int,
    p_name text,
    p_type text
) returns int as
$$
declare
    v_account_id int;
    v_internal_type text;
begin
    -- determine internal type based on account type
    if p_type = 'asset' then
        v_internal_type := 'asset_like';
    else
        v_internal_type := 'liability_like';
    end if;
    
    -- create the account
    insert into data.accounts (ledger_id, name, type, internal_type)
    values (p_ledger_id, p_name, p_type, v_internal_type)
    returning id into v_account_id;
    
    return v_account_id;
end;
$$ language plpgsql;

-- Refactor the get_account_transactions function to include balance information
-- This enhances the function to show running balances for each transaction,
-- which provides better visibility into account history and makes reconciliation easier
-- First drop the existing function to avoid return type change error
drop function if exists api.get_account_transactions(int);

-- Then create the new function with the balance column
create or replace function api.get_account_transactions(p_account_id int)
returns table (
    date timestamptz,
    category text,
    description text,
    type text,
    amount bigint,
    balance bigint  -- New column for transaction balance
) as $$
begin
    return query
    with account_transactions as (
        -- Transactions where this account is debited (money going out for asset accounts)
        select 
            t.date,
            a.name as category,
            t.description,
            'outflow' as type,
            -t.amount as amount,
            t.id as transaction_id,
            row_number() over (order by t.date desc, t.id desc) as row_num
        from data.transactions t
        join data.accounts a on t.credit_account_id = a.id
        where t.debit_account_id = p_account_id
        
        union all
        
        -- Transactions where this account is credited (money coming in for asset accounts)
        select 
            t.date,
            a.name as category,
            t.description,
            'inflow' as type,
            t.amount as amount,
            t.id as transaction_id,
            row_number() over (order by t.date desc, t.id desc) as row_num
        from data.transactions t
        join data.accounts a on t.debit_account_id = a.id
        where t.credit_account_id = p_account_id
    )
    select 
        at.date,
        at.category,
        at.description,
        at.type,
        at.amount,
        b.balance  -- Get the balance from the balances table
    from account_transactions at
    left join data.balances b on 
        b.transaction_id = at.transaction_id and 
        b.account_id = p_account_id
    order by at.date desc, at.row_num;
end;
$$ language plpgsql;

-- Create or replace the view to match the new function
drop view if exists data.account_transactions;
create view data.account_transactions as
select * from api.get_account_transactions(4);  -- Default account ID
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
drop function if exists api.get_account_transactions(int);
drop function if exists api.add_account(int, text, text);

-- Also drop the view if it exists
drop view if exists data.account_transactions;
-- +goose StatementEnd
