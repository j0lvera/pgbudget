-- +goose Up
-- +goose StatementBegin

-- Trigger for data.transactions table (internal audit timestamp)
create trigger transactions_updated_at_tg
    before update
    on data.transactions
    for each row
execute procedure utils.set_updated_at_fn();

-- Triggers for the NEW api.transactions view (which was api.simple_transactions)
-- These are renamed from simple_transactions_*_tg and now target api.transactions
create trigger transactions_insert_tg -- RENAMED from simple_transactions_insert_tg
    instead of insert
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_insert_fn(); -- Calls the simple util

create trigger transactions_update_tg -- RENAMED from simple_transactions_update_tg
    instead of update
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_update_fn(); -- Calls the simple util

create trigger transactions_delete_tg -- RENAMED from simple_transactions_delete_tg
    instead of delete
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_delete_fn(); -- Calls the simple util

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Drop trigger from data.transactions table
drop trigger if exists transactions_updated_at_tg on data.transactions;

-- Drop the new triggers from the consolidated api.transactions view
drop trigger if exists transactions_insert_tg on api.transactions;
drop trigger if exists transactions_update_tg on api.transactions;
drop trigger if exists transactions_delete_tg on api.transactions;

-- Recreate the trigger for the ORIGINAL api.transactions view (manual double-entry)
-- This relies on utils.transactions_insert_single_fn being available (recreated by utils down migration).
-- This also relies on the original api.transactions view being recreated by the views down migration.
create trigger transactions_insert_tg
    instead of insert
    on api.transactions -- Targets the original api.transactions view (manual double-entry)
    for each row
execute function utils.transactions_insert_single_fn();

-- Recreate triggers for the ORIGINAL api.simple_transactions view
-- This relies on utils.simple_transactions_*_fn being available (they are dropped and would need to be
-- recreated if this down migration is run standalone after the utils down migration,
-- but goose runs downs in reverse order, so utils functions should be there).
-- This also relies on the original api.simple_transactions view being recreated by the views down migration.
create trigger simple_transactions_insert_tg
    instead of insert
    on api.simple_transactions -- Targets the original api.simple_transactions view
    for each row
execute function utils.simple_transactions_insert_fn();

create trigger simple_transactions_update_tg
    instead of update
    on api.simple_transactions -- Targets the original api.simple_transactions view
    for each row
execute function utils.simple_transactions_update_fn();

create trigger simple_transactions_delete_tg
    instead of delete
    on api.simple_transactions -- Targets the original api.simple_transactions view
    for each row
execute function utils.simple_transactions_delete_fn();

-- +goose StatementEnd
