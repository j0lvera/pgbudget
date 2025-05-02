-- +goose Up
-- +goose StatementBegin
-- function to create a new account
create or replace function api.add_account(
    p_ledger_id int,
    p_user_id int,
    p_name text,
    p_type text
) returns int as
$$
declare
    v_account_id    int;
    v_internal_type text;
begin
    -- determine internal type based on account type
    if p_type = 'asset' then
        v_internal_type := 'asset_like';
    else
        v_internal_type := 'liability_like';
    end if;

    -- create the account
       insert into data.accounts (ledger_id, user_id, name, type, internal_type)
       values (p_ledger_id, p_user_id, p_name, p_type, v_internal_type)
    returning id into v_account_id;

    return v_account_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
drop function if exists api.add_account(int, int, text, text);
-- +goose StatementEnd
