-- +goose Up

-- Remove existing functions first to avoid conflicts during rename/recreate
DROP FUNCTION IF EXISTS api.assign_to_category(text, timestamptz, text, bigint, int);
DROP FUNCTION IF EXISTS api.add_category(text, text);
DROP FUNCTION IF EXISTS utils.find_category(text, text, text); -- Drop old version if exists

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

-- function to assign money from Income to a category (public API)
-- takes ledger uuid, date, description, amount, and target category uuid
-- returns a record matching the structure of api.transactions view
create or replace function api.assign_to_category(
    ledger_uuid text,
    date timestamptz,
    description text,
    amount bigint,
    category_uuid text
) returns table(uuid text, description text, amount bigint, metadata jsonb, date timestamptz, ledger_uuid text, debit_account_uuid text, credit_account_uuid text) as
$$
declare
    v_ledger_id          int;
    v_income_account_id  int;
    v_income_account_uuid text;
    v_category_account_id int;
    v_user_data          text := utils.get_user(); -- get current user context
    v_transaction_uuid   text;
    v_metadata           jsonb; -- To hold metadata if fetched from insert
begin
    -- find the ledger ID for the specified UUID and user
    -- ensures the user owns the ledger
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = ledger_uuid
       and l.user_data = v_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', ledger_uuid;
    end if;

    -- validate amount is positive
    if amount <= 0 then
        raise exception 'Assignment amount must be positive: %', amount;
    end if;

    -- find the Income account ID and UUID for this ledger and user
    -- Income account is always type 'equity'
    select a.id, a.uuid
      into v_income_account_id, v_income_account_uuid
      from data.accounts a
     where a.ledger_id = v_ledger_id
       and a.user_data = v_user_data
       and a.name = 'Income'
       and a.type = 'equity';

    -- raise exception if Income account not found (should not happen if ledger setup is correct)
    if v_income_account_id is null then
        raise exception 'Income account not found for ledger %', v_ledger_id;
    end if;

    -- find the target category account ID for this ledger and user using its UUID
    -- ensures the target account is an 'equity' type (a category)
    select a.id
      into v_category_account_id
      from data.accounts a
     where a.uuid = category_uuid
       and a.ledger_id = v_ledger_id
       and a.user_data = v_user_data
       and a.type = 'equity';

    -- raise exception if the target category is not found or doesn't belong to the user/ledger
    if v_category_account_id is null then
        raise exception 'Category with UUID % not found or does not belong to ledger % for current user', category_uuid, v_ledger_id;
    end if;

    -- create the transaction directly in data.transactions
    -- debit: Income account (decreasing unassigned funds)
    -- credit: Target category account (increasing assigned funds)
    -- associate transaction with the user
    insert into data.transactions (ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data)
    values (
        v_ledger_id,
        description,
        date,
        amount,
        v_income_account_id, -- Debit Income ID
        v_category_account_id, -- Credit Category ID
        v_user_data
    )
    returning uuid, metadata into v_transaction_uuid, v_metadata; -- Get UUID and metadata of the new transaction

   -- Manually construct the return record matching api.transactions structure
   -- Use RETURN QUERY SELECT to return the structured data
   return query
   select
       v_transaction_uuid::text,    -- transaction uuid
       description::text,           -- transaction description
       amount::bigint,              -- transaction amount
       v_metadata::jsonb,           -- transaction metadata (if any)
       date::timestamptz,           -- transaction date
       ledger_uuid::text,           -- ledger uuid
       v_income_account_uuid::text, -- debit account uuid (Income)
       category_uuid::text;         -- credit account uuid (Target Category)

end;
$$ language plpgsql volatile security invoker; -- runs with invoker privileges, relies on user context checks

-- +goose StatementEnd

-- Grant permissions on new API functions to the web user role
GRANT EXECUTE ON FUNCTION api.add_category(text, text) TO pgb_web_user;
GRANT EXECUTE ON FUNCTION api.assign_to_category(text, timestamptz, text, bigint, text) TO pgb_web_user;


-- +goose Down
-- +goose StatementBegin

-- drop the functions in reverse order of creation and revoke permissions
REVOKE EXECUTE ON FUNCTION api.add_category(text, text) FROM pgb_web_user;
REVOKE EXECUTE ON FUNCTION api.assign_to_category(text, timestamptz, text, bigint, text) FROM pgb_web_user;

drop function if exists api.assign_to_category(text, timestamptz, text, bigint, text);
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
