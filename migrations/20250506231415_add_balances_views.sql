-- +goose Up
-- +goose StatementBegin

-- create the API view for balances (read-only)
create or replace view api.balances with (security_invoker = true) as
select b.uuid,
       b.previous_balance,
       b.delta,
       b.balance,
       b.operation_type,
       b.user_data,
       b.created_at,
       acc.uuid::text as account_uuid,
       tx.uuid::text  as transaction_uuid
  from data.balances b
         left join data.accounts acc on acc.id = b.account_id
         left join data.transactions tx on tx.id = b.transaction_id;


-- Create an API function to expose budget status with UUIDs instead of internal IDs
create or replace function api.get_budget_status(
    p_ledger_uuid text
) returns table (
    category_uuid text,
    category_name text,
    budgeted bigint,
    activity bigint,
    balance bigint
) as $$
begin
    -- Simply call the utils function and transform the results for the API
    -- The exception from utils.get_budget_status will propagate up if ledger is not found
    return query
    select 
        bs.account_uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(p_ledger_uuid) bs;
end;
$$ language plpgsql stable security invoker;


-- Create a simplified API function that just passes through to the utils function
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
    -- Simply call the utils function and return the results
    -- The exception from utils.get_account_transactions will propagate up if account is not found
    return query
    select * from utils.get_account_transactions(p_account_uuid);
end;
$$ language plpgsql stable security invoker;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

    -- Remove the API function
    drop function if exists api.get_account_transactions(text);
    drop function if exists api.get_budget_status(text);

    drop view if exists api.balances;

-- +goose StatementEnd
