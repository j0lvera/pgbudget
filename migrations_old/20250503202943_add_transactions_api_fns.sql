-- +goose Up
-- +goose StatementBegin

-- The api.transactions and api.simple_transactions views and their associated trigger functions/triggers
-- have been moved to an earlier migration (20250402001312_add_transactions_views.sql)
-- to resolve dependencies for functions like api.assign_to_category.

-- This migration file originally contained these views and triggers.
-- It is kept in the sequence but is now effectively empty for the 'Up' direction
-- regarding those specific objects.

-- Future API functions related to transactions could be added here if needed.

select 1; -- Placeholder to ensure the statement block is valid

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- The corresponding 'Down' operations for the views and trigger functions
-- are now located in the 'Down' section of migration
-- 20250402001312_add_transactions_views.sql.

-- If this migration added other objects in the future, their 'Down' operations would go here.

select 1; -- Placeholder to ensure the statement block is valid

-- +goose StatementEnd
