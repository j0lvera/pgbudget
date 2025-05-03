-- +goose Up
-- +goose StatementBegin

-- it’s a good practice to create a dedicated role for connecting to the database, instead of using the
-- highly privileged postgres role. the authenticator role is used for connecting to the database and
-- should be configured to have very limited access. it is a chameleon whose job is to “become” other
-- users to service authenticated HTTP requests.
create role pgb_web_authr login noinherit nocreatedb nocreaterole nosuperuser;

-- users who authenticate with the API.
create role pgb_web_user nologin;

-- grant the authenticator role the ability to switch to the authorized and anonymous roles:
grant pgb_web_user to pgb_web_authr;

-- the authorized role will have the authority to do anything to the ledgers table.
grant usage on schema api to pgb_web_user;
grant usage on schema data to pgb_web_user;
grant usage on schema utils to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on schema utils from pgb_web_user;
revoke all on schema data from pgb_web_user;
revoke all on schema api from pgb_web_user;

drop role if exists pgb_web_user;
drop role if exists pgb_web_authr;

-- +goose StatementEnd