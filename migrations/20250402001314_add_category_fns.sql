-- +goose Up

-- Remove existing functions first to avoid conflicts during rename/recreate
DROP FUNCTION IF EXISTS api.assign_to_category(text, timestamptz, text, bigint, text); -- Drop new if exists from previous step
DROP FUNCTION IF EXISTS api.assign_to_category(text, timestamptz, text, bigint, int); -- Drop old if exists
DROP FUNCTION IF EXISTS api.add_category(text, text);
DROP FUNCTION IF EXISTS utils.find_category(text, text, text);
DROP FUNCTION IF EXISTS utils.add_category(text, text, text); -- Drop new if exists from previous step
DROP FUNCTION IF EXISTS utils.assign_to_category(text, timestamptz, text, bigint, text, text); -- Drop potential new util function if exists

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

    -- validate the category name is not empty
    if p_name is null or trim(p_name) = '' then
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

-- +goose StatementEnd

-- +goose StatementBegin

-- function to create a new category account (public API)
-- takes ledger uuid and category name
-- returns a record matching the structure of api.accounts view
create or replace function api.add_category(
    ledger_uuid text,
    name text
) returns table(uuid text, name text, type data.account_type, description text, metadata jsonb, user_data text, ledger_uuid text) as
$$
declare
    v_util_result data.accounts; -- holds the result from the utility function
begin
    -- Call the internal utility function to perform the insertion
    -- implicitly uses the current user's context via utils.get_user() default
    v_util_result := utils.add_category(ledger_uuid, name);

    -- Manually construct the return record matching api.accounts structure
    -- Use RETURN QUERY SELECT to return the structured data
    return query
    select
        v_util_result.uuid::text,        -- account uuid
        v_util_result.name::text,        -- account name
        v_util_result.type::data.account_type, -- account type
        v_util_result.description::text, -- account description
        v_util_result.metadata::jsonb,   -- account metadata
        v_util_result.user_data::text,   -- user associated with the account
        ledger_uuid::text;               -- use the input ledger_uuid directly

end;
$$ language plpgsql volatile security invoker; -- runs with invoker privileges, relies on utils function for security

-- +goose StatementEnd


-- +goose StatementBegin

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


-- +goose StatementBegin

-- function to assign money from Income to a category (internal utility)
-- performs the core logic: finds accounts, validates, inserts transaction
-- returns necessary info for the API layer
create or replace function utils.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text,
    p_user_data text = utils.get_user()
) returns table(transaction_uuid text, income_account_uuid text, metadata jsonb) as
$$
declare
    v_ledger_id          int;
    v_income_account_id  int;
    v_income_account_uuid_local text; -- Renamed to avoid conflict with return column name
    v_category_account_id int;
    v_transaction_uuid_local text; -- Renamed
    v_metadata_local jsonb; -- Renamed
begin
    -- find the ledger ID for the specified UUID and user
    select l.id into v_ledger_id from data.ledgers l where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    if v_ledger_id is null then raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid; end if;

    -- validate amount is positive
    if p_amount <= 0 then raise exception 'Assignment amount must be positive: %', p_amount; end if;

    -- find the Income account ID and UUID
    select a.id, a.uuid into v_income_account_id, v_income_account_uuid_local from data.accounts a
     where a.ledger_id = v_ledger_id and a.user_data = p_user_data and a.name = 'Income' and a.type = 'equity';
    if v_income_account_id is null then raise exception 'Income account not found for ledger %', v_ledger_id; end if;

    -- find the target category account ID
    select a.id into v_category_account_id from data.accounts a
     where a.uuid = p_category_uuid and a.ledger_id = v_ledger_id and a.user_data = p_user_data and a.type = 'equity';
    if v_category_account_id is null then raise exception 'Category with UUID % not found or does not belong to ledger % for current user', p_category_uuid, v_ledger_id; end if;

    -- create the transaction (debit Income, credit Category)
    insert into data.transactions (ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data)
    values (v_ledger_id, p_description, p_date, p_amount, v_income_account_id, v_category_account_id, p_user_data)
    returning uuid, metadata into v_transaction_uuid_local, v_metadata_local;

   -- Return the essential details
   return query select v_transaction_uuid_local, v_income_account_uuid_local, v_metadata_local;

end;
$$ language plpgsql volatile security definer; -- Security definer for controlled execution

-- +goose StatementEnd


-- +goose StatementBegin

-- function to assign money from Income to a category (public API)
-- wrapper around the utils function, handles API input/output formatting
create or replace function api.assign_to_category(
    ledger_uuid text,
    date timestamptz,
    description text,
    amount bigint,
    category_uuid text
) returns table(uuid text, description text, amount bigint, metadata jsonb, date timestamptz, ledger_uuid text, debit_account_uuid text, credit_account_uuid text) as
$$
declare
    v_util_result record; -- To store the result from utils.assign_to_category
begin
    -- Call the internal utility function
    select * into v_util_result from utils.assign_to_category(
        p_ledger_uuid   => ledger_uuid,
        p_date          => date,
        p_description   => description,
        p_amount        => amount,
        p_category_uuid => category_uuid
        -- p_user_data defaults to utils.get_user() in the utils function
    );

   -- Manually construct the return record matching api.transactions structure
   -- using data from input parameters and the result of the utils function
   return query
   select
       v_util_result.transaction_uuid::text,
       description::text,
       amount::bigint,
       v_util_result.metadata::jsonb,
       date::timestamptz,
       ledger_uuid::text,
       v_util_result.income_account_uuid::text, -- Debit is Income (from utils result)
       category_uuid::text;                     -- Credit is Category (from input)

end;
$$ language plpgsql volatile security invoker; -- Runs as the calling user

-- +goose StatementEnd

-- Grant permissions on new API functions
GRANT EXECUTE ON FUNCTION api.add_category(text, text) TO pgb_web_user;
GRANT EXECUTE ON FUNCTION api.assign_to_category(text, timestamptz, text, bigint, text) TO pgb_web_user;


-- +goose Down
-- +goose StatementBegin

-- drop the functions in reverse order of creation and revoke permissions
REVOKE EXECUTE ON FUNCTION api.add_category(text, text) FROM pgb_web_user;
REVOKE EXECUTE ON FUNCTION api.assign_to_category(text, timestamptz, text, bigint, text) FROM pgb_web_user;

drop function if exists api.assign_to_category(text, timestamptz, text, bigint, text);
drop function if exists utils.assign_to_category(text, timestamptz, text, bigint, text, text); -- Drop the new util function
drop function if exists utils.find_category(text, text, text);
drop function if exists api.add_category(text, text);
drop function if exists utils.add_category(text, text, text);

-- +goose StatementEnd

-- Recreate old functions if needed for rollback (optional, depends on strategy)
-- The following section is commented out as it represents the previous function signatures.
-- Uncomment and complete if a full rollback to the previous state (including old function signatures) is required.
-- +goose StatementBegin
-- -- Recreate old api.add_category (returning int)
-- -- create or replace function api.add_category(p_ledger_uuid text, p_name text) returns int ...
-- -- Recreate old api.assign_to_category (taking int category_id)
-- -- create or replace function api.assign_to_category(p_ledger_uuid text, p_date timestamptz, p_description text, p_amount bigint, p_category_id int) returns int ...
-- -- Recreate old utils.find_category (returning int)
-- -- create or replace function utils.find_category(p_ledger_uuid text, p_category_name text, p_user_data text = utils.get_user()) returns int ...
-- +goose StatementEnd
