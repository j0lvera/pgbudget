-- +goose Up
-- +goose StatementBegin

-- function to create a new category account (public API)
-- takes ledger uuid and category name
-- returns a record matching the structure of api.accounts view
create or replace function api.add_category(
    ledger_uuid text,
    name text -- Keep user-friendly input parameter name
) returns setof api.accounts as -- Use SETOF <view_name>
$$
declare
    v_util_result data.accounts; -- holds the result from the utility function
begin
    -- Call the internal utility function to perform the insertion
    -- implicitly uses the current user's context via utils.get_user() default
    v_util_result := utils.add_category(ledger_uuid, name);

    -- Return the newly created account by querying the corresponding API view
    -- This ensures the output matches the view definition exactly.
    return query
        select *
          from api.accounts a -- Query the view
         where a.uuid = v_util_result.uuid; -- Filter for the created account UUID

end;
$$ language plpgsql volatile security invoker; -- runs with invoker privileges, relies on utils function for security

grant execute on function api.add_category(text, text) to pgb_web_user;

-- function to assign money from Income to a category (public API)
-- wrapper around the utils function, handles API input/output formatting
create or replace function api.assign_to_category(
    -- Use p_ prefix for input parameters to avoid collision with return type columns
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
) returns setof api.transactions as
$$
declare
    v_util_result record; -- To store the result from utils.assign_to_category (transaction_uuid, income_account_uuid, metadata)
begin
    -- Call the internal utility function
    select * into v_util_result from utils.assign_to_category(
            p_ledger_uuid   := p_ledger_uuid, -- Pass renamed params
            p_date          := p_date,
            p_description   := p_description,
            p_amount        := p_amount,
            p_category_uuid := p_category_uuid
        -- p_user_data defaults to utils.get_user()
                                     );

    -- --- MODIFY RETURN LOGIC BELOW ---
    -- Return the result by selecting directly from the utils function output
    -- and combining with input parameters. This avoids querying api.transactions view.
    -- Use explicit casts and aliases matching the api.transactions view columns.
    return query
        select
            v_util_result.transaction_uuid::text as uuid,
            p_description::text as description, -- Use input param directly
            p_amount::bigint as amount,         -- Use input param directly
            v_util_result.metadata::jsonb as metadata, -- From utils result
            p_date::timestamptz as date,         -- Use input param directly
            p_ledger_uuid::text as ledger_uuid, -- Use input param directly
            v_util_result.income_account_uuid::text as debit_account_uuid, -- From utils result
            p_category_uuid::text as credit_account_uuid; -- Use input param directly
    -- --- END MODIFICATION ---

end;
$$ language plpgsql volatile security invoker; -- Runs as the calling user

grant execute on function api.assign_to_category(text, timestamptz, text, bigint, text) to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke execute on function api.assign_to_category(text, timestamptz, text, bigint, text) from pgb_web_user;

drop function if exists api.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
) cascade; -- Drop the public API function

revoke execute on function api.add_category(text, text) from pgb_web_user;

drop function if exists api.add_category(
    ledger_uuid text,
    name text
) cascade; -- Drop the public API function

-- +goose StatementEnd
