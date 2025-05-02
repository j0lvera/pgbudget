-- +goose Up
-- +goose StatementBegin

-- schema that holds all user authentication related tables
create schema if not exists auth;

-- schema that holds all transactions, accounts, ledgers related tables
create schema if not exists data;

-- schema that holds all data accessing/manipulating functions
create schema if not exists api;

create schema if not exists utils;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop schema if exists utils;
drop schema if exists api;
drop schema if exists data;
drop schema if exists auth;
-- +goose StatementEnd
