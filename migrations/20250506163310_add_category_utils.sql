-- +goose Up
-- +goose StatementBegin

-- function to create a new category account (internal)
-- takes ledger uuid, category name, and user_data
-- returns the full data.accounts record for the new category
create or replace function utils.add_category(
    p_ledger_uuid text,
    p_name text,
    p_user_data text = utils.get_user()
) returns data.accounts as -- Return the full account record
$$
declare
    v_ledger_id   int;
    v_account_record data.accounts;
begin
    -- find the ledger ID for the specified UUID and user
    -- ensures the user owns the ledger
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- validate the category name is not empty (trim once)
    p_name := trim(p_name);
    if p_name is null or p_name = '' then
        raise exception 'Category name cannot be empty';
    end if;

    -- create the category account (equity type, liability_like behavior)
    -- associate it with the user using user_data
       insert into data.accounts (ledger_id, name, type, internal_type, user_data)
       values (v_ledger_id, p_name, 'equity', 'liability_like', p_user_data)
    returning * into v_account_record; -- return the newly created account record

    return v_account_record;
end;
$$ language plpgsql security definer; -- runs with definer privileges for controlled data access

-- function to create multiple categories at once (internal)
-- takes ledger uuid, array of category names, and user_data
-- returns a set of data.accounts records for the new categories
create or replace function utils.add_categories(
    p_ledger_uuid text,
    p_names text[],
    p_user_data text = utils.get_user()
) returns setof data.accounts as
$$
declare
    v_ledger_id int;
    v_name text;
    v_account_record data.accounts;
begin
    -- find the ledger ID for the specified UUID and user
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- Process each category name
    foreach v_name in array p_names
    loop
        -- Skip empty names after trimming
        v_name := trim(v_name);
        if v_name = '' then
            continue;
        end if;

        -- Create the category account
        begin
            insert into data.accounts (ledger_id, name, type, internal_type, user_data)
            values (v_ledger_id, v_name, 'equity', 'liability_like', p_user_data)
            returning * into v_account_record;
            
            -- Return this record
            return next v_account_record;
        exception
            when unique_violation then
                -- Re-raise the exception to be consistent with single category creation
                raise exception 'Category with name "%" already exists in this ledger', v_name;
        end;
    end loop;

    return;
end;
$$ language plpgsql security definer;


-- function to find a category by name in a ledger (internal utility)
-- takes ledger uuid, category name, and user_data
-- returns the UUID of the found category account
create or replace function utils.find_category(
    p_ledger_uuid text,
    p_category_name text,
    p_user_data text = utils.get_user()
) returns text as -- Return UUID
$$
declare
    v_ledger_id int;
    v_category_uuid text;
begin
    -- find the ledger ID for the specified UUID and user
    -- ensures the user owns the ledger
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the category account UUID for this ledger, user, and name
    -- ensures the account is of type 'equity' (a category)
    select a.uuid
      into v_category_uuid
      from data.accounts a
     where a.ledger_id = v_ledger_id
       and a.user_data = p_user_data
       and a.name = p_category_name
       and a.type = 'equity';

    -- return the found UUID (will be null if not found)
    return v_category_uuid;
end;
$$ language plpgsql stable security definer; -- runs with definer privileges, read-only

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop function if exists utils.add_category(text, text, text) cascade;
drop function if exists utils.add_categories(text, text[], text) cascade;
drop function if exists utils.find_category(text, text, text) cascade;
-- +goose StatementEnd
