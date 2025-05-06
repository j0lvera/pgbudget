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
       (select a.uuid from data.accounts a where a.id = b.account_id)::text as account_uuid,
       (select t.uuid from data.transactions t where t.id = b.transaction_id)::text as transaction_uuid
  from data.balances b;

-- grant only SELECT permissions to the web user (read-only)
grant select on api.balances to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

    revoke all on api.balances from pgb_web_user;

    drop view if exists api.balances;

-- +goose StatementEnd
