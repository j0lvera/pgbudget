-- +goose Up
-- +goose StatementBegin

-- simple function to handle transaction soft deletes
create or replace function utils.handle_transaction_soft_delete()
returns trigger as $$
declare
    v_debit_prev_balance bigint;
    v_credit_prev_balance bigint;
    v_debit_delta bigint;
    v_credit_delta bigint;
    v_debit_type text;
    v_credit_type text;
begin
    -- get current balances
    select coalesce(new_balance, 0) into v_debit_prev_balance
    from data.balances 
    where account_id = NEW.debit_account_id 
    order by created_at desc, id desc 
    limit 1;
    
    select coalesce(new_balance, 0) into v_credit_prev_balance
    from data.balances 
    where account_id = NEW.credit_account_id 
    order by created_at desc, id desc 
    limit 1;
    
    -- get account types
    select internal_type into v_debit_type 
    from data.accounts 
    where id = NEW.debit_account_id;
    
    select internal_type into v_credit_type 
    from data.accounts 
    where id = NEW.credit_account_id;
    
    -- calculate reversal deltas (opposite of original transaction)
    if v_debit_type = 'asset_like' then
        v_debit_delta := -NEW.amount;
    else
        v_debit_delta := NEW.amount;
    end if;
    
    if v_credit_type = 'asset_like' then
        v_credit_delta := NEW.amount;
    else
        v_credit_delta := -NEW.amount;
    end if;
    
    -- insert reversal balance records
    insert into data.balances (
        account_id, transaction_id, ledger_id, previous_balance, delta, new_balance, operation_type, user_data
    )
    values 
        (NEW.debit_account_id, NEW.id, NEW.ledger_id, v_debit_prev_balance, v_debit_delta, v_debit_prev_balance + v_debit_delta, 'soft_delete', NEW.user_data),
        (NEW.credit_account_id, NEW.id, NEW.ledger_id, v_credit_prev_balance, v_credit_delta, v_credit_prev_balance + v_credit_delta, 'soft_delete', NEW.user_data);
    
    return NEW;
end;
$$ language plpgsql security definer;

-- balances table is append-only (we never update balance records, only insert new ones)
-- so we don't need an updated_at trigger
-- create trigger balances_updated_at_tg
--     before update
--     on data.balances
--     for each row
-- execute procedure utils.set_updated_at_fn();

-- create the trigger on transactions table for inserts
create trigger update_account_balance_trigger
    after insert on data.transactions
    for each row
execute function utils.update_account_balance();

-- create trigger for soft deletes
create trigger transactions_after_soft_delete_trigger
    after update of deleted_at on data.transactions
    for each row
    when (new.deleted_at is not null and old.deleted_at is null)
execute function utils.handle_transaction_soft_delete();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop triggers
drop trigger if exists transactions_after_soft_delete_trigger on data.transactions;
drop trigger if exists update_account_balance_trigger on data.transactions;
-- drop trigger if exists balances_updated_at_tg on data.balances; -- commented out since trigger is commented out

-- drop functions
drop function if exists utils.handle_transaction_soft_delete();
drop function if exists utils.update_account_balance();

-- +goose StatementEnd
