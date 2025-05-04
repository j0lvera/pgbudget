-- +goose Up
-- +goose StatementBegin

-- The api.accounts view and its associated INSERT trigger function (utils.accounts_insert_single_fn)
-- have been moved to an earlier migration (20250402001313_add_accounts_view.sql)
-- to resolve dependencies for functions like api.add_category.

-- This migration file originally contained the view and trigger.
-- It is kept in the sequence but is now effectively empty for the 'Up' direction
-- regarding those specific objects.

-- Future API functions related to accounts (e.g., update, delete) could be added here.

select 1; -- Placeholder to ensure the statement block is valid

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- The corresponding 'Down' operations for the view and trigger function
-- are now located in the 'Down' section of migration
-- 20250402001313_add_accounts_view.sql.

-- If this migration added other objects in the future, their 'Down' operations would go here.

select 1; -- Placeholder to ensure the statement block is valid

-- +goose StatementEnd
