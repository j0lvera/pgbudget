-- +goose Up
-- +goose StatementBegin
create schema if not exists auth;

create table auth.users
(
    id         bigint generated always as identity primary key,

    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,

    email      text        not null,
    password   text        not null,
    metadata   jsonb,

    constraint users_email_length_check check (length(email) <= 255),
    -- Argon2id hash length
    constraint users_password_length_check check (length(password) >= 60)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table if exists auth.users;

drop schema if exists auth;
-- +goose StatementEnd