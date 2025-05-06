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
       -- Subquery to get the ledger's UUID based on the account's ledger_id
       (select l.uuid from data.ledgers l where l.id = a.ledger_id)::text as ledger_uuid
  from data.accounts a
 where a.user_data = utils.get_user(); -- Apply RLS-like filtering directly in the view

grant select, insert, update, delete on api.accounts to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.accounts from pgb_web_user;

drop view if exists api.accounts;

-- +goose StatementEnd
