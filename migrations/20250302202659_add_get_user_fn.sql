-- +goose Up
-- +goose StatementBegin
create or replace function utils.get_user() returns bigint as
$$
select id
  from auth.users
 where email = current_setting('request.jwt.claims', true)::json ->> 'email'
$$ language sql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
    drop function if exists utils.get_user();
-- +goose StatementEnd
