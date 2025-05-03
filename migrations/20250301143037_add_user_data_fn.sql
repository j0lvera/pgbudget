-- +goose Up
-- +goose StatementBegin

create or replace function utils.get_user() returns text as
$$
begin
    -- check if jwt claims are null
    if current_setting('request.jwt.claims', true) is null then
        raise exception 'jwt claims are null. authentication required.';
    end if;
    
    -- return the user_data from jwt claims
    return current_setting('request.jwt.claims', true)::json->>'user_data';
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.get_user();

-- +goose StatementEnd
