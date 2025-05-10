-- +goose Up
-- +goose StatementBegin

-- function to handle transaction updates and update balances accordingly
create or replace function utils.transactions_after_update_fn()
returns trigger as $$
declare
    v_account_id int;
    v_previous_balance bigint;
    v_current_balance bigint;
    v_delta bigint;
    v_internal_type text;
    v_ledger_id int;
begin
    -- get the ledger_id from the transaction
    v_ledger_id := new.ledger_id;
    
    -- first, reverse the effects of the original transaction
    -- for each account affected by the original transaction
    for v_account_id in 
        select distinct account_id 
        from data.balances 
        where transaction_id = new.id and operation_type = 'transaction_insert'
    loop
        -- get the account's internal type
        select internal_type into v_internal_type
        from data.accounts
        where id = v_account_id;
        
        -- get the current balance
        select balance into v_previous_balance
        from data.balances
        where account_id = v_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- get the original delta (from the transaction_insert operation)
        select delta into v_delta
        from data.balances
        where transaction_id = new.id and account_id = v_account_id and operation_type = 'transaction_insert'
        limit 1;
        
        -- reverse the delta (apply with opposite sign)
        v_current_balance := v_previous_balance + v_delta; -- add the original delta to reverse it
        
        -- insert reversal balance entry
        insert into data.balances (
            account_id, transaction_id, previous_balance, delta, balance, operation_type, user_data, ledger_id
        ) values (
            v_account_id, new.id, v_previous_balance, v_delta, v_current_balance, 'transaction_update_reversal', new.user_data, v_ledger_id
        );
    end loop;
    
    -- now apply the updated transaction
    -- for debit account
    select internal_type into v_internal_type
    from data.accounts
    where id = new.debit_account_id;
    
    -- get the current balance after reversal
    select balance into v_previous_balance
    from data.balances
    where account_id = new.debit_account_id
    order by created_at desc, id desc
    limit 1;
    
    -- calculate delta based on internal_type
    if v_internal_type = 'asset_like' then
        v_delta := new.amount; -- debit increases asset-like accounts
    else
        v_delta := -new.amount; -- debit decreases liability-like accounts
    end if;
    
    v_current_balance := v_previous_balance + v_delta;
    
    -- insert application balance entry for debit account
    insert into data.balances (
        account_id, transaction_id, previous_balance, delta, balance, operation_type, user_data, ledger_id
    ) values (
        new.debit_account_id, new.id, v_previous_balance, v_delta, v_current_balance, 'transaction_update_application', new.user_data, v_ledger_id
    );
    
    -- for credit account
    select internal_type into v_internal_type
    from data.accounts
    where id = new.credit_account_id;
    
    -- get the current balance after reversal
    select balance into v_previous_balance
    from data.balances
    where account_id = new.credit_account_id
    order by created_at desc, id desc
    limit 1;
    
    -- calculate delta based on internal_type
    if v_internal_type = 'asset_like' then
        v_delta := -new.amount; -- credit decreases asset-like accounts
    else
        v_delta := new.amount; -- credit increases liability-like accounts
    end if;
    
    v_current_balance := v_previous_balance + v_delta;
    
    -- insert application balance entry for credit account
    insert into data.balances (
        account_id, transaction_id, previous_balance, delta, balance, operation_type, user_data, ledger_id
    ) values (
        new.credit_account_id, new.id, v_previous_balance, v_delta, v_current_balance, 'transaction_update_application', new.user_data, v_ledger_id
    );
    
    return new;
end;
$$ language plpgsql;

-- function to handle transaction deletes and update balances accordingly
create or replace function utils.handle_transaction_delete_balance()
returns trigger as $$
declare
    v_account_id int;
    v_previous_balance bigint;
    v_current_balance bigint;
    v_delta bigint;
    v_ledger_id int;
begin
    -- get the ledger_id from the transaction
    v_ledger_id := old.ledger_id;
    
    -- for each account affected by the original transaction
    for v_account_id in 
        select distinct account_id 
        from data.balances 
        where transaction_id = old.id and operation_type = 'transaction_insert'
    loop
        -- get the current balance
        select balance into v_previous_balance
        from data.balances
        where account_id = v_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- get the original delta (from the transaction_insert operation)
        select delta into v_delta
        from data.balances
        where transaction_id = old.id and account_id = v_account_id and operation_type = 'transaction_insert'
        limit 1;
        
        -- reverse the delta (apply with opposite sign)
        v_delta := -v_delta; -- negate the original delta
        v_current_balance := v_previous_balance + v_delta;
        
        -- insert delete balance entry
        insert into data.balances (
            account_id, transaction_id, previous_balance, delta, balance, operation_type, user_data, ledger_id
        ) values (
            v_account_id, old.id, v_previous_balance, v_delta, v_current_balance, 'transaction_delete', old.user_data, v_ledger_id
        );
    end loop;
    
    return old;
end;
$$ language plpgsql;

-- function to handle transaction soft deletes and update balances accordingly
create or replace function utils.transactions_after_soft_delete_fn()
returns trigger as $$
declare
    v_account_id int;
    v_previous_balance bigint;
    v_current_balance bigint;
    v_delta bigint;
    v_ledger_id int;
begin
    -- get the ledger_id from the transaction
    v_ledger_id := new.ledger_id;
    
    -- for each account affected by the original transaction
    for v_account_id in 
        select distinct account_id 
        from data.balances 
        where transaction_id = new.id and operation_type = 'transaction_insert'
    loop
        -- get the current balance
        select balance into v_previous_balance
        from data.balances
        where account_id = v_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- get the original delta (from the transaction_insert operation)
        select delta into v_delta
        from data.balances
        where transaction_id = new.id and account_id = v_account_id and operation_type = 'transaction_insert'
        limit 1;
        
        -- reverse the delta (apply with opposite sign)
        v_delta := -v_delta; -- negate the original delta
        v_current_balance := v_previous_balance + v_delta;
        
        -- insert soft delete balance entry
        insert into data.balances (
            account_id, transaction_id, previous_balance, delta, balance, operation_type, user_data, ledger_id
        ) values (
            v_account_id, new.id, v_previous_balance, v_delta, v_current_balance, 'transaction_soft_delete', new.user_data, v_ledger_id
        );
    end loop;
    
    return new;
end;
$$ language plpgsql;

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

-- create trigger for soft deletes
create trigger transactions_after_soft_delete_trigger
    after update of deleted_at on data.transactions
    for each row
    when (new.deleted_at is not null and old.deleted_at is null)
execute function utils.transactions_after_soft_delete_fn();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop trigger if exists transactions_after_delete_balance_trigger on data.transactions;

drop trigger if exists transactions_after_update_balance_trigger on data.transactions;

drop trigger if exists update_account_balance_trigger on data.transactions;

drop trigger if exists balances_updated_at_tg on data.balances;

drop function if exists utils.transactions_after_soft_delete_fn();

drop function if exists utils.handle_transaction_delete_balance();

drop function if exists utils.transactions_after_update_fn();

-- +goose StatementEnd
