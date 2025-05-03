-- +goose Up
-- +goose StatementBegin

-- create a function to handle transaction insertion through the API view
create or replace function utils.transactions_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id bigint;
    v_debit_account_id bigint;
    v_credit_account_id bigint;
begin
    -- get the ledger_id for denormalization
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid;

    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', NEW.ledger_uuid;
    end if;

    -- get the debit account id
    select a.id
      into v_debit_account_id
      from data.accounts a
     where a.uuid = NEW.debit_account_uuid
       and a.ledger_id = v_ledger_id;

    if v_debit_account_id is null then
        raise exception 'debit account with uuid % not found in ledger %', NEW.debit_account_uuid, NEW.ledger_uuid;
    end if;

    -- get the credit account id
    select a.id
      into v_credit_account_id
      from data.accounts a
     where a.uuid = NEW.credit_account_uuid
       and a.ledger_id = v_ledger_id;

    if v_credit_account_id is null then
        raise exception 'credit account with uuid % not found in ledger %', NEW.credit_account_uuid, NEW.ledger_uuid;
    end if;

    -- insert the transaction into the transactions table
    insert into data.transactions (description, amount, debit_account_id, credit_account_id, ledger_id, metadata)
    values (NEW.description,
            NEW.amount,
            v_debit_account_id,
            v_credit_account_id,
            v_ledger_id,
            NEW.metadata)
    returning uuid, description, amount, metadata, user_data into
        new.uuid, new.description, new.amount, new.metadata, new.user_data;

    return new;
end;
$$ language plpgsql;

-- create the API view for transactions
create or replace view api.transactions with (security_invoker = true) as
select t.uuid,
       t.description,
       t.amount,
       t.metadata,
       t.user_data,
       t.created_at,
       (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text as ledger_uuid,
       (select a.uuid from data.accounts a where a.id = t.debit_account_id)::text as debit_account_uuid,
       (select a.uuid from data.accounts a where a.id = t.credit_account_id)::text as credit_account_uuid
  from data.transactions t;

-- create the insert trigger for the transactions view
create trigger transactions_insert_tg
    instead of insert
    on api.transactions
    for each row
execute function utils.transactions_insert_single_fn();

-- grant permissions to the web user
grant all on api.transactions to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions

revoke all on api.transactions from pgb_web_user;

drop trigger if exists transactions_insert_tg on api.transactions;

drop view if exists api.transactions;

drop function if exists utils.transactions_insert_single_fn();

-- +goose StatementEnd
