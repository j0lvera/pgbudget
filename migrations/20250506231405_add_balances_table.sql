-- +goose Up
-- +goose StatementBegin

-- This migration is now empty - balances table removed for simplification
-- Balance calculations will be done on-demand from transactions

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Nothing to drop since we're not creating anything

-- +goose StatementEnd
