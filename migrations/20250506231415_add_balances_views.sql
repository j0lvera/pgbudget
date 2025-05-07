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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

    revoke all on api.balances from pgb_web_user;

    drop view if exists api.balances;

-- +goose StatementEnd
