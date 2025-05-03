-- +goose Up
-- +goose StatementBegin
-- function to create a new account
create or replace function utils.add_account(
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
                metadata    jsonb
            )
as
$$
declare
    v_internal_type text;
begin
    -- determine internal type based on account type
    if p_type = 'asset' then
        v_internal_type := 'asset_like';
    else
        v_internal_type := 'liability_like';
    end if;

    -- insert and return the requested fields in one operation
    return query
        insert into data.accounts (ledger_id, user_data, name, type, internal_type)
            values (p_ledger_id, p_user_data, p_name, p_type, v_internal_type)
            returning accounts.uuid, accounts.name, accounts.type, accounts.description, accounts.metadata;
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
                metadata    jsonb
            )
as
$$
begin
    select *
      from utils.add_account(
              (select id from data.ledgers l where l.uuid = p_ledger_uuid),
              utils.get_user(),
              p_name,
              p_type
           );
end;
$$ language plpgsql;

-- add a view to access the accounts table but with limited columns, we don't want to return the id.
create view api.accounts as
select uuid, name, description, type, internal_type, metadata
  from data.accounts;

-- allow authenticated user to access the accounts view.
grant select on api.accounts to pgb_web_user;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
revoke select on api.accounts from pgb_web_user;
drop view if exists api.accounts;
drop function if exists api.add_account(text, text, text);
drop function if exists utils.add_account(int, text, text, text);
-- +goose StatementEnd
