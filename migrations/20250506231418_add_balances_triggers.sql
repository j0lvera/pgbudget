-- +goose Up
-- +goose StatementBegin

-- create trigger for updated_at
create trigger balances_updated_at_tg
    before update
    on data.balances
    for each row
execute procedure utils.set_updated_at_fn();

-- create the trigger on transactions table
create trigger update_account_balance_trigger
    after insert on data.transactions
    for each row
execute function utils.update_account_balance();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop trigger if exists update_account_balance_trigger on data.transactions;

drop trigger if exists balances_updated_at_tg on data.balances;

-- +goose StatementEnd
