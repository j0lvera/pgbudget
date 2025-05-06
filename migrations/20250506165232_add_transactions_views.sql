-- +goose Up
-- +goose StatementBegin

-- create the API view for transactions
create or replace view api.transactions with (security_invoker = true) as
select t.uuid,
       t.description,
       t.amount,
       t.metadata,
       t.date,
       (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text          as ledger_uuid,
       (select a.uuid from data.accounts a where a.id = t.debit_account_id)::text  as debit_account_uuid,
       (select a.uuid from data.accounts a where a.id = t.credit_account_id)::text as credit_account_uuid
  from data.transactions t;

-- grant permissions to the web user
grant select, insert, update, delete on api.transactions to pgb_web_user;

-- Create the simple_transactions view
create or replace view api.simple_transactions with (security_invoker = true) as
select
    t.uuid,
    t.description,
    t.amount,
    t.metadata,
    t.date,
    -- Determine transaction type based on account relationships
    case
        when a_debit.internal_type = 'asset_like' and a_debit.id = t.debit_account_id then 'inflow'
        when a_credit.internal_type = 'asset_like' and a_credit.id = t.credit_account_id then 'outflow'
        when a_debit.internal_type = 'liability_like' and a_debit.id = t.debit_account_id then 'outflow'
        when a_credit.internal_type = 'liability_like' and a_credit.id = t.credit_account_id then 'inflow'
        end as type,
    -- Determine which account is the bank/credit card account
    case
        when a_debit.type in ('asset', 'liability') then a_debit.uuid
        when a_credit.type in ('asset', 'liability') then a_credit.uuid
        end as account_uuid,
    -- Determine which account is the category
    case
        when a_debit.type = 'equity' then a_debit.uuid
        when a_credit.type = 'equity' then a_credit.uuid
        end as category_uuid,
    (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text as ledger_uuid
  from
      data.transactions t
      join data.accounts a_debit on t.debit_account_id = a_debit.id
      join data.accounts a_credit on t.credit_account_id = a_credit.id;

grant select, insert, update, delete on api.simple_transactions to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.transactions from pgb_web_user;
revoke all on api.simple_transactions from pgb_web_user;

drop trigger if exists transactions_insert_tg on api.transactions;
drop trigger if exists simple_transactions_insert_tg on api.simple_transactions;
drop trigger if exists simple_transactions_update_tg on api.simple_transactions;
drop trigger if exists simple_transactions_delete_tg on api.simple_transactions;

drop view if exists api.transactions;
drop view if exists api.simple_transactions;

drop function if exists utils.transactions_insert_single_fn();
drop function if exists utils.simple_transactions_insert_fn();
drop function if exists utils.simple_transactions_update_fn();
drop function if exists utils.simple_transactions_delete_fn();


-- +goose StatementEnd
