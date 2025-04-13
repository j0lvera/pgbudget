-- +goose Up
-- +goose StatementBegin
create schema if not exists auth;

create table auth.organizations
(
    id         bigint generated always as identity primary key,

    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,

    name       text        not null,
    metadata   jsonb,

    constraint organizations_name_length_check check (char_length(name) <= 255)
);

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

create table auth.memberships
(
    id              bigint generated always as identity primary key,

    created_at      timestamptz not null default current_timestamp,
    updated_at      timestamptz not null default current_timestamp,

    role            text        not null,

    organization_id bigint      not null references auth.organizations (id) on delete cascade,
    user_id         bigint      not null references auth.users (id) on delete cascade,

    constraint memberships_role_check check (role in ('owner', 'admin', 'editor', 'member')),
    constraint memberships_user_unique unique (organization_id, user_id)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table if exists auth.memberships;
drop table if exists auth.users;
drop table if exists auth.organizations;

drop schema if exists auth;
-- +goose StatementEnd