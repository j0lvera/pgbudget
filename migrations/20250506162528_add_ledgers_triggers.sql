-- +goose Up
-- +goose StatementBegin

-- Trigger function to set the updated_at timestamp
create trigger ledgers_updated_at_tg
    before update
    on data.ledgers
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger ledgers_updated_at_tg on data.ledgers is 'Automatically updates the updated_at timestamp before any update operation on a ledger.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin


drop trigger if exists ledgers_updated_at_tg on data.ledgers;

-- +goose StatementEnd
