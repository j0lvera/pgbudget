-- +goose Up
-- +goose StatementBegin

-- remove only update/delete triggers to make transactions immutable
-- keep insert trigger so users can still create transactions via the simplified api
drop trigger if exists transactions_update_tg on api.transactions;
drop trigger if exists transactions_delete_tg on api.transactions;

-- drop the update/delete trigger functions
drop function if exists utils.simple_transactions_update_fn();
drop function if exists utils.simple_transactions_delete_fn();

-- add comment explaining the change
comment on view api.transactions is 'Transactions are immutable after creation. Use api.correct_transaction() or api.delete_transaction() to modify existing transactions.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- note: this down migration would need to recreate the old triggers
-- for now, just drop the comment
comment on view api.transactions is null;

-- +goose StatementEnd
