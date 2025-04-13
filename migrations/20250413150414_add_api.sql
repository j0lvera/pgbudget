-- +goose Up
-- +goose StatementBegin
create role pgb_web_authr login noinherit nocreatedb nocreaterole nosuperuser;
create role pgb_web_user nologin;
create role pgb_web_anon nologin;

grant pgb_web_user to pgb_web_authr;
grant pgb_web_anon to pgb_web_authr;

grant usage on schema data to pgb_web_anon;
grant select on data.ledgers to pgb_web_anon;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
revoke select on data.ledgers from pgb_web_anon;
revoke usage on schema data from pgb_web_anon;

drop role if exists pgb_web_user;
drop role if exists pgb_web_anon;
drop role if exists pgb_web_authr;
-- +goose StatementEnd
