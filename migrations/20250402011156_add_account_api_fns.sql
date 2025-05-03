-- +goose Up
-- +goose StatementBegin

-- function to create a new account
create or replace function utils.accounts_insert_single(
    p_ledger_id bigint,
    p_user_data text,
    p_name text,
    p_type text
)
    returns table
            (
                uuid        text,
                name        text,
                type        text,
                description text,
                metadata    jsonb,
                ledger_uuid text
            )
as
$$
declare
    v_ledger_uuid   text;
begin
    select l.uuid
      from data.ledgers l
     where l.id = p_ledger_id
      into v_ledger_uuid;

    -- insert and return the requested fields in one operation
    -- internal_type will be set by the trigger
    return query
        insert into data.accounts (ledger_id, user_data, name, type)
            values (p_ledger_id, p_user_data, p_name, p_type)
            returning accounts.uuid, accounts.name, accounts.type, accounts.description, accounts.metadata, v_ledger_uuid;
end;
$$ language plpgsql;

create or replace function api.add_account(
    p_ledger_uuid text,
    p_name text,
    p_type text
)
    returns table
            (
                uuid        text,
                name        text,
                type        text,
                description text,
                metadata    jsonb,
                ledger_uuid text
            )
as
$$
begin
    return query
        select *
          from utils.accounts_insert_single(
                  (select id from data.ledgers l where l.uuid = p_ledger_uuid),
                  utils.get_user(),
                  p_name,
                  p_type
               );
end;
$$ language plpgsql;

create or replace function api.get_accounts()
    returns table
            (
                uuid        text,
                name        text,
                type        text,
                description text,
                metadata    jsonb,
                ledger_uuid text
            )
as
$$
begin
    return query
        select a.uuid,
               a.name,
               a.type,
               a.description,
               a.metadata,
               (select l.uuid from data.ledgers l where l.id = a.ledger_id)::text as ledger_uuid
          from data.accounts a;
end;
$$ language plpgsql;

create or replace view api.accounts as
select a.uuid,
       a.name,
       a.type,
       a.description,
       a.metadata,
       (select l.uuid from data.ledgers l where l.id = a.ledger_id)::text as ledger_uuid
  from data.accounts a;

-- allow authenticated user to access the accounts view.
grant all on api.accounts to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions

drop view if exists api.accounts;

drop function if exists api.get_accounts();

drop function if exists api.add_account(text, text, text);

drop function if exists utils.accounts_insert_single(bigint, text, text, text);

-- +goose StatementEnd
