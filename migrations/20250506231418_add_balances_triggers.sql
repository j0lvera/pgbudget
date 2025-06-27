-- +goose Up
-- +goose StatementBegin

-- no triggers needed - balances are calculated on-demand from transactions
-- this keeps the system simple and always accurate

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- nothing to drop since we're not creating any triggers

-- +goose StatementEnd
