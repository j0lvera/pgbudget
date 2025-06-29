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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop view if exists api.accounts;

-- +goose StatementEnd
