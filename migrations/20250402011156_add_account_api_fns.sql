-- +goose Up
-- +goose StatementBegin

create or replace function utils.accounts_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id bigint;
begin
    -- get the ledger_id for denormalization
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid;

    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', NEW.ledger_uuid;
    end if;

    -- insert the account into the accounts table
       insert into data.accounts (name, type, description, metadata, ledger_id)
       values (NEW.name,
               NEW.type,
               NEW.description,
               NEW.metadata,
               v_ledger_id)
    returning uuid, name, type, description, metadata, user_data into
        new.uuid, new.name, new.type, new.description, new.metadata, new.user_data;

    return new;
end;
$$ language plpgsql;

create or replace view api.accounts with (security_barrier) as
select a.uuid,
       a.name,
       a.type,
       a.description,
       a.metadata,
       a.user_data,
       (select l.uuid from data.ledgers l where l.id = a.ledger_id)::text as ledger_uuid
  from data.accounts a;

create trigger accounts_insert_tg
    instead of insert
    on api.accounts
    for each row
execute function utils.accounts_insert_single_fn();

-- allow authenticated user to access the accounts view.
grant all on api.accounts to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions

revoke all on api.accounts from pgb_web_user;

drop trigger if exists accounts_insert_tg on api.accounts;

drop view if exists api.accounts;

drop function if exists utils.accounts_insert_single_fn();

-- +goose StatementEnd
