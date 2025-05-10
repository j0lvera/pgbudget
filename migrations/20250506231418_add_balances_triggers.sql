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

-- create the trigger on transactions table for updates
create trigger transactions_after_update_balance_trigger
    after update of amount, debit_account_id, credit_account_id on data.transactions
    for each row
    when (old.amount is distinct from new.amount or
          old.debit_account_id is distinct from new.debit_account_id or
          old.credit_account_id is distinct from new.credit_account_id)
execute function utils.transactions_after_update_fn();

-- create the trigger on transactions table for deletes
create trigger transactions_after_delete_balance_trigger
    after delete on data.transactions
    for each row
execute function utils.handle_transaction_delete_balance();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop trigger if exists transactions_after_delete_balance_trigger on data.transactions;

drop trigger if exists transactions_after_update_balance_trigger on data.transactions;

drop trigger if exists update_account_balance_trigger on data.transactions;

drop trigger if exists balances_updated_at_tg on data.balances;

-- +goose StatementEnd
