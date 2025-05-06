-- +goose Up
-- +goose StatementBegin

create trigger transactions_updated_at_tg
    before update
    on data.transactions
    for each row
execute procedure utils.set_updated_at_fn();

-- create the insert trigger for the transactions view
create trigger transactions_insert_tg
    instead of insert
    on api.transactions
    for each row
execute function utils.transactions_insert_single_fn();

-- Create triggers for the simple_transactions view
create trigger simple_transactions_insert_tg
    instead of insert
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_insert_fn();

create trigger simple_transactions_update_tg
    instead of update
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_update_fn();

create trigger simple_transactions_delete_tg
    instead of delete
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_delete_fn();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
SELECT 'down SQL query';
-- +goose StatementEnd
