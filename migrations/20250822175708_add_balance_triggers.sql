-- +goose Up
-- +goose StatementBegin

-- trigger function to create balance snapshots when transactions are inserted
create or replace function utils.transaction_balance_snapshot_fn() returns trigger as $$
begin
    -- create balance snapshots for the new transaction
    perform utils.create_balance_snapshots(new.id);
    return new;
end;
$$ language plpgsql security definer;

-- trigger to automatically create balance snapshots when transactions are added
create trigger transaction_balance_snapshot_tg
    after insert on data.transactions
    for each row
    execute function utils.transaction_balance_snapshot_fn();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop trigger if exists transaction_balance_snapshot_tg on data.transactions;
drop function if exists utils.transaction_balance_snapshot_fn();

-- +goose StatementEnd
