-- +goose Up
-- +goose StatementBegin

-- it’s a good practice to create a dedicated role for connecting to the database, instead of using the
-- highly privileged postgres role. the authenticator role is used for connecting to the database and
-- should be configured to have very limited access. it is a chameleon whose job is to “become” other
-- users to service authenticated HTTP requests.
create role pgb_web_authr login noinherit nocreatedb nocreaterole nosuperuser;

-- users who authenticate with the API.
create role pgb_web_user nologin;

-- role to use for anonymous web requests.
create role pgb_web_anon nologin;

-- grant the authenticator role the ability to switch to the authorized and anonymous roles:
grant pgb_web_user to pgb_web_authr;
grant pgb_web_anon to pgb_web_authr;

-- the anonymous role has permission to access things in the data schema,
-- and to read rows in the ledgers table.
grant usage on schema data to pgb_web_anon;
grant select on data.ledgers to pgb_web_anon;

-- the authorized role will have the authority to do anything to the ledgers table.
grant usage on schema data to pgb_web_user;
grant all on data.ledgers to pgb_web_user;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
revoke all on data.ledgers from pgb_web_user;
revoke all on schema data from pgb_web_user;

revoke select on data.ledgers from pgb_web_anon;
revoke usage on schema data from pgb_web_anon;

drop role if exists pgb_web_user;
drop role if exists pgb_web_anon;
drop role if exists pgb_web_authr;
-- +goose StatementEnd
