-- +goose Up
-- +goose StatementBegin

-- API view for accounts, joining with ledgers to expose ledger_uuid
create or replace view api.accounts with (security_invoker = true) as
select a.uuid,
       a.name,
       a.type,
       a.description,
       a.metadata,
       a.user_data,
       l.uuid::text as ledger_uuid -- Get ledger_uuid from the joined data.ledgers table
  from data.accounts a
  join data.ledgers l on a.ledger_id = l.id; -- Join accounts with ledgers

grant select, insert, update, delete on api.accounts to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.accounts from pgb_web_user;

drop view if exists api.accounts;

-- +goose StatementEnd
