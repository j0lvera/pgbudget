-- +goose Up
-- +goose StatementBegin
-- function to find a category by name within a ledger
create or replace function api.find_category(
    p_ledger_id int,
    p_category_name text
) returns int as $$
declare
    v_category_id int;
begin
    -- find the category id
    select id into v_category_id
    from data.accounts
    where ledger_id = p_ledger_id 
      and name = p_category_name
      and type = 'equity'
    limit 1;
    
    return v_category_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the function if it exists
drop function if exists api.find_category(int, text);
-- +goose StatementEnd
