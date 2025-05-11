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

-- grant only SELECT permissions to the web user (read-only)
grant select on api.balances to pgb_web_user;

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
declare
    v_ledger_id bigint;
    v_user_data text := utils.get_user();
begin
    -- Resolve the ledger UUID to its internal ID
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = v_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- Call the utils function with the resolved ledger ID and return the results
    -- with UUIDs instead of internal IDs for the API
    return query
    select 
        a.uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(v_ledger_id) bs
    join data.accounts a on bs.id = a.id
    where a.user_data = v_user_data;
end;
$$ language plpgsql stable security invoker;

-- Grant execute permission to the web user role
grant execute on function api.get_budget_status(text) to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

    -- Remove the API function
    drop function if exists api.get_budget_status(text);

    revoke all on api.balances from pgb_web_user;

    drop view if exists api.balances;

-- +goose StatementEnd
