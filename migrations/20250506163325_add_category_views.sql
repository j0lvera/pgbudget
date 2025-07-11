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

-- API function for batch category creation
-- takes ledger uuid and array of category names
-- returns a set of records matching the structure of api.accounts view
create or replace function api.add_categories(
    ledger_uuid text,
    names text[]
) returns setof api.accounts as
$$
declare
    v_account_record record;
begin
    -- Call the utility function and return results through the API view
    for v_account_record in select * from utils.add_categories(ledger_uuid, names)
    loop
        -- Return each account through the API view
        return query
            select *
              from api.accounts a
             where a.uuid = v_account_record.uuid;
    end loop;

    return;
end;
$$ language plpgsql volatile security invoker;

-- Grant execute permission to web user

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.add_category(
    ledger_uuid text,
    name text
) cascade; -- Drop the public API function

drop function if exists api.add_categories(
    ledger_uuid text,
    names text[]
) cascade; -- Drop the batch category creation function

-- +goose StatementEnd
