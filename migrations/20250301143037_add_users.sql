-- +goose Up
-- +goose StatementBegin
create table auth.users
(
    id         bigint generated always as identity primary key,
    uuid       text        not null default utils.nanoid(8),

    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,

    email      text        not null,
    password   text        not null,
    metadata   jsonb,

    constraint users_uuid_unique unique (uuid),
    constraint users_email_length_check check (length(email) <= 255),
    -- Argon2id hash length
    constraint users_password_length_check check (length(password) >= 60)
);

create trigger users_updated_at_tg
    before update
    on auth.users
    for each row
execute procedure utils.set_updated_at_fn();

-- util function to get the current user id
create or replace function utils.get_user() returns bigint as
$$
select id
  from auth.users
 where email = current_setting('request.jwt.claims', true)::json ->> 'email'
$$ language sql;

-- allow authenticated user to read from the users table
grant select on auth.users to pgb_web_user;
grant usage, select on sequence auth.users_id_seq to pgb_web_user;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
revoke select on auth.users from pgb_web_user;
revoke usage, select on sequence auth.users_id_seq from pgb_web_user;

drop function if exists utils.get_user();

drop table if exists auth.users;

drop trigger if exists users_updated_at_tg on auth.users;
-- +goose StatementEnd
