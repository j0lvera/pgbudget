-- +goose Up
-- +goose StatementBegin
-- function to create a new account
create or replace function api.add_account(
    p_ledger_id int,
    p_user_id int,
    p_name text,
    p_type text
)
    returns text -- Changed to return just the UUID as text
as
$$
declare
    v_internal_type text;
    v_uuid          text;
begin
    -- determine internal type based on account type
    if p_type = 'asset' then
        v_internal_type := 'asset_like';
    else
        v_internal_type := 'liability_like';
    end if;

    -- create the account and get the UUID
       insert into data.accounts (ledger_id, user_id, name, type, internal_type)
       values (p_ledger_id, p_user_id, p_name, p_type, v_internal_type)
    returning uuid into v_uuid;

    -- return just the UUID
    return v_uuid;
end;
$$ language plpgsql;

-- create or replace function api.get_accounts() returns setof data.accounts
--     language sql
--     stable as
-- $$
-- select *
--   from data.accounts;
-- $$;

create view api.accounts as
select uuid, name, description, type, internal_type, metadata
  from data.accounts;

grant select on api.accounts to pgb_web_user;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
revoke select on api.accounts from pgb_web_user;
drop view if exists api.accounts;
-- drop function if exists api.get_accounts();
drop function if exists api.add_account(int, int, text, text);
-- +goose StatementEnd
