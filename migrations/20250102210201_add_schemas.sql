-- +goose Up
-- +goose StatementBegin

-- holds data tables
create schema if not exists data;

-- holds read/write functions
create schema if not exists api;

-- holds utility functions unrelated to the data tables
create schema if not exists utils;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop schema if exists utils;
drop schema if exists api;
drop schema if exists data;

-- +goose StatementEnd
