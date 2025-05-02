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
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table if exists auth.users;

drop trigger if exists users_updated_at_tg on auth.users;
-- +goose StatementEnd