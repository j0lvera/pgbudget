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


-- ADD THE NEW UPDATE TRIGGER FUNCTION HERE
-- trigger function for handling INSTEAD OF UPDATE on api.accounts view
create or replace function utils.accounts_update_single_fn()
returns trigger as
$$
declare
    v_ledger_id int;
    v_account_id int;
    v_user_data text := utils.get_user(); -- Get current user context
begin
    -- Ensure the ledger_uuid provided (if changed) resolves to a valid ledger for the user
    if NEW.ledger_uuid is not null and NEW.ledger_uuid <> OLD.ledger_uuid then
        select l.id into v_ledger_id
          from data.ledgers l
         where l.uuid = NEW.ledger_uuid and l.user_data = v_user_data;

        if v_ledger_id is null then
            raise exception 'Target ledger with UUID % not found for current user', NEW.ledger_uuid;
        end if;
    else
        -- If ledger_uuid is not being changed, or is null in NEW (meaning no change requested for it)
        -- use the existing ledger_id from the OLD record.
        -- We still need to fetch the ID for the OLD.ledger_uuid to use in the update if ledger_uuid isn't changing.
        select l.id into v_ledger_id
          from data.ledgers l
         where l.uuid = OLD.ledger_uuid; -- No user_data check here as OLD record implies ownership already via RLS on view

        if v_ledger_id is null then
             -- This should not happen if OLD.ledger_uuid is valid.
            raise exception 'Original ledger with UUID % could not be resolved to an ID.', OLD.ledger_uuid;
        end if;
    end if;

    -- Get the internal ID of the account being updated
    -- RLS on the view already ensures the user can see OLD.uuid.
    -- We need to ensure the update respects ownership if user_data was part of the check.
    select a.id into v_account_id
      from data.accounts a
     where a.uuid = OLD.uuid and a.user_data = v_user_data; -- Re-check ownership for the update operation

    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user to update', OLD.uuid;
    end if;

    -- Update the underlying data.accounts table
    update data.accounts
       set name = coalesce(NEW.name, OLD.name),
           type = coalesce(NEW.type, OLD.type),
           description = coalesce(NEW.description, OLD.description),
           metadata = coalesce(NEW.metadata, OLD.metadata),
           ledger_id = v_ledger_id -- This uses the resolved v_ledger_id
           -- user_data is NOT updated here to prevent ownership changes.
           -- updated_at is handled by the accounts_updated_at_tg trigger on data.accounts
     where id = v_account_id;

    -- Populate NEW record for returning from the view operation.
    NEW.uuid := OLD.uuid; -- UUID does not change
    -- If NEW.ledger_uuid was not provided in the update, it will be OLD.ledger_uuid.
    -- If it was provided, it's already NEW.ledger_uuid.
    -- The user_data is from the original record and should not be changed by this update.
    NEW.user_data := OLD.user_data;
    -- The other fields (name, type, description, metadata) in NEW are already populated
    -- by the values from the UPDATE statement on the view.

    return NEW;
end;
$$ language plpgsql volatile security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.accounts_insert_single_fn() cascade; -- Corrected: no params
drop function if exists utils.accounts_update_single_fn() cascade;
drop function if exists utils.set_account_internal_type_fn() cascade; -- Ensure cascade if other functions depend on it

-- +goose StatementEnd
