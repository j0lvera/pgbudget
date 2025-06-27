-- +goose Up
-- +goose StatementBegin

-- simplified api function to expose budget status
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
    -- simply call the utils function and transform the results for the api
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

-- simplified api function that passes through to the utils function
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
    -- simply call the utils function and return the results
    return query
    select * from utils.get_account_transactions(p_account_uuid);
end;
$$ language plpgsql stable security invoker;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- remove the api functions
drop function if exists api.get_account_transactions(text);
drop function if exists api.get_budget_status(text);

-- +goose StatementEnd
