-- +goose Up
-- +goose StatementBegin

-- creates a trigger function in the utils schema to set internal_type based on account type.
create or replace function utils.set_account_internal_type_fn()
    returns trigger as
$$
begin
    -- determine internal_type based on the account's 'type'.
    -- 'asset' and 'expense' types are 'asset_like' (debits increase balance).
    -- 'liability', 'equity', and 'revenue' types are 'liability_like' (credits increase balance).
    if new.type = 'asset' or new.type = 'expense' then
        new.internal_type := 'asset_like';
    else
        new.internal_type := 'liability_like';
    end if;

    return new;
end;
$$ language plpgsql;

comment on function utils.set_account_internal_type_fn() is 'Trigger function to automatically set the `internal_type` of an account based on its `type` before insert or update.';

-- Trigger function to handle inserts into the api.accounts view
create or replace function utils.accounts_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id   bigint;
    v_user_data   text := utils.get_user(); -- Explicitly capture the current user context
begin
    -- get the ledger_id based on the provided ledger_uuid
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data; -- Ensure user (from v_user_data) owns the ledger

    -- Raise exception if the ledger is not found for the current user
    if v_ledger_id is null then
        -- Include the user context in the error for better debugging
        raise exception 'Ledger with UUID % not found for current user %', NEW.ledger_uuid, v_user_data;
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

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.accounts_insert_single_fn();

drop function if exists utils.set_account_internal_type_fn();

-- +goose StatementEnd
