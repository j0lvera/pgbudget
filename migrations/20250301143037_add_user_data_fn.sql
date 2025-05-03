-- +goose Up
-- +goose StatementBegin

create or replace function utils.get_user() returns text as
$$
select
    case
        when current_setting('request.jwt.claims', true) is null then null
        else current_setting('request.jwt.claims', true)::json->>'user_data'
        end;
$$ language sql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.get_user();

-- +goose StatementEnd