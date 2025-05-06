-- +goose Up
-- +goose StatementBegin

-- This migration defines the api.accounts view and its associated INSERT trigger.
-- It is placed before migrations that depend on the api.accounts type (like api.add_category).

-- Trigger function to handle inserts into the api.accounts view
create or replace function utils.accounts_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id bigint;
begin
    -- get the ledger_id based on the provided ledger_uuid
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = utils.get_user(); -- Ensure user owns the ledger

    -- Raise exception if the ledger is not found for the current user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- insert the account into the base data.accounts table
    -- The internal_type will be set automatically by the accounts_set_internal_type_tg trigger
    -- The user_data will be set automatically by the default value on the table
       insert into data.accounts (name, type, description, metadata, ledger_id)
       values (NEW.name,
               NEW.type,
               NEW.description,
               NEW.metadata,
               v_ledger_id)
    -- Return the newly inserted row's data matching the view structure
    -- Note: user_data is fetched from the actual inserted row, not NEW.user_data
    returning uuid, name, type, description, metadata, user_data into
        new.uuid, new.name, new.type, new.description, new.metadata, new.user_data;

    -- The ledger_uuid is already part of the NEW record passed to the trigger,
    -- so it doesn't need to be explicitly returned or set here.

    return new; -- Return the NEW record populated with generated values
end;
$$ language plpgsql security definer; -- Security definer to allow controlled insert

-- +goose StatementEnd

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

-- +goose StatementEnd

-- +goose StatementBegin

-- Trigger to route INSERT operations on the view to the trigger function
create trigger accounts_insert_tg
    instead of insert
    on api.accounts
    for each row
execute function utils.accounts_insert_single_fn();

-- +goose StatementEnd

-- +goose StatementBegin

-- Grant permissions to the web user role
-- Allow SELECT for reading accounts via the view
-- Allow INSERT for creating accounts via the view (handled by the trigger)
-- Allow UPDATE/DELETE if needed in the future (add corresponding triggers/functions)
grant select, insert on api.accounts to pgb_web_user;

-- Grant usage on the utility function schema if not already granted elsewhere
grant usage on schema utils to pgb_web_user;
-- Grant execute on the specific trigger function
grant execute on function utils.accounts_insert_single_fn() to pgb_web_user;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Revoke permissions first
revoke all on api.accounts from pgb_web_user;
revoke execute on function utils.accounts_insert_single_fn() from pgb_web_user;
-- Consider revoking schema usage if this is the only function used, otherwise leave it

-- Drop the trigger
drop trigger if exists accounts_insert_tg on api.accounts;

-- Drop the view
drop view if exists api.accounts;

-- Drop the trigger function
drop function if exists utils.accounts_insert_single_fn();

-- +goose StatementEnd

