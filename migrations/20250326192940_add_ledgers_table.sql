-- +goose Up
-- +goose StatementBegin
create schema if not exists data;
create schema if not exists api;

create table data.ledgers
(
    id          bigint generated always as identity primary key,

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    metadata    jsonb,

    constraint ledgers_name_length_check check (char_length(name) <= 255),
    constraint ledgers_description_length_check check (char_length(description) <= 255)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table data.ledgers;
drop schema data;
-- +goose StatementEnd
