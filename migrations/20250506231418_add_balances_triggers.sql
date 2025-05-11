-- +goose Up
-- +goose StatementBegin

-- function to handle transaction updates and update balances accordingly
create or replace function utils.transactions_after_update_fn()
returns trigger as $$
declare
    v_accounts_info jsonb;
    v_balance bigint;
    v_ledger_id bigint := NEW.ledger_id;
    v_user_data text := NEW.user_data;
    v_debit_delta bigint;
    v_credit_delta bigint;
    v_debit_account_changed boolean;
    v_credit_account_changed boolean;
    v_amount_changed boolean;
begin
    -- Determine what changed
    v_debit_account_changed := OLD.debit_account_id != NEW.debit_account_id;
    v_credit_account_changed := OLD.credit_account_id != NEW.credit_account_id;
    v_amount_changed := OLD.amount != NEW.amount;
    
    -- If nothing relevant changed, exit early
    if not (v_debit_account_changed or v_credit_account_changed or v_amount_changed) then
        return NEW;
    end if;
    
    -- Get latest balances and account types in a single query
    with account_data as (
        select 
            a.id, a.internal_type,
            (select balance from data.balances 
             where account_id = a.id 
             order by created_at desc, id desc limit 1) as current_balance
        from 
            data.accounts a
        where 
            a.id in (OLD.debit_account_id, OLD.credit_account_id, NEW.debit_account_id, NEW.credit_account_id)
    )
    select 
        jsonb_object_agg(id::text, jsonb_build_object(
            'type', internal_type,
            'balance', coalesce(current_balance, 0)
        )) into v_accounts_info
    from account_data;
    
    -- Handle accounts that changed
    
    -- 1. If debit account changed, reverse effect on old debit account
    if v_debit_account_changed then
        -- Calculate reversal delta for old debit account
        if v_accounts_info->OLD.debit_account_id::text->>'type' = 'asset_like' then
            v_debit_delta := -OLD.amount; -- Reverse the debit
        else
            v_debit_delta := OLD.amount; -- Reverse the debit
        end if;
        
        -- Insert reversal balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            OLD.debit_account_id, NEW.id, v_ledger_id,
            (v_accounts_info->OLD.debit_account_id::text->>'balance')::bigint,
            v_debit_delta,
            (v_accounts_info->OLD.debit_account_id::text->>'balance')::bigint + v_debit_delta,
            'transaction_update_reversal', v_user_data
        );
        
        -- Apply effect to new debit account
        if v_accounts_info->NEW.debit_account_id::text->>'type' = 'asset_like' then
            v_debit_delta := NEW.amount;
        else
            v_debit_delta := -NEW.amount;
        end if;
        
        -- Get updated balance for new debit account
        select balance into v_balance
        from data.balances
        where account_id = NEW.debit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert application balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.debit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_debit_delta,
            coalesce(v_balance, 0) + v_debit_delta,
            'transaction_update_application', v_user_data
        );
    -- If only amount changed, update the debit account
    elsif v_amount_changed then
        -- First add reversal entry
        if v_accounts_info->NEW.debit_account_id::text->>'type' = 'asset_like' then
            v_debit_delta := -OLD.amount; -- Reverse the old debit
        else
            v_debit_delta := OLD.amount; -- Reverse the old debit
        end if;
        
        -- Get current balance
        select balance into v_balance
        from data.balances
        where account_id = NEW.debit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert reversal balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.debit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_debit_delta,
            coalesce(v_balance, 0) + v_debit_delta,
            'transaction_update_reversal', v_user_data
        );
        
        -- Then add application entry with new amount
        if v_accounts_info->NEW.debit_account_id::text->>'type' = 'asset_like' then
            v_debit_delta := NEW.amount; -- Apply the new debit
        else
            v_debit_delta := -NEW.amount; -- Apply the new debit
        end if;
        
        -- Get updated balance after reversal
        select balance into v_balance
        from data.balances
        where account_id = NEW.debit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert application balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.debit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_debit_delta,
            coalesce(v_balance, 0) + v_debit_delta,
            'transaction_update_application', v_user_data
        );
    end if;
    
    -- 2. If credit account changed, reverse effect on old credit account
    if v_credit_account_changed then
        -- Calculate reversal delta for old credit account
        if v_accounts_info->OLD.credit_account_id::text->>'type' = 'asset_like' then
            v_credit_delta := OLD.amount; -- Reverse the credit
        else
            v_credit_delta := -OLD.amount; -- Reverse the credit
        end if;
        
        -- Insert reversal balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            OLD.credit_account_id, NEW.id, v_ledger_id,
            (v_accounts_info->OLD.credit_account_id::text->>'balance')::bigint,
            v_credit_delta,
            (v_accounts_info->OLD.credit_account_id::text->>'balance')::bigint + v_credit_delta,
            'transaction_update_reversal', v_user_data
        );
        
        -- Apply effect to new credit account
        if v_accounts_info->NEW.credit_account_id::text->>'type' = 'asset_like' then
            v_credit_delta := -NEW.amount;
        else
            v_credit_delta := NEW.amount;
        end if;
        
        -- Get updated balance for new credit account
        select balance into v_balance
        from data.balances
        where account_id = NEW.credit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert application balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.credit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_credit_delta,
            coalesce(v_balance, 0) + v_credit_delta,
            'transaction_update_application', v_user_data
        );
    -- If only amount changed, update the credit account
    elsif v_amount_changed then
        -- First add reversal entry
        if v_accounts_info->NEW.credit_account_id::text->>'type' = 'asset_like' then
            v_credit_delta := -OLD.amount; -- Reverse the old credit (asset-like: credit decreases balance)
        else
            v_credit_delta := -OLD.amount; -- Reverse the old credit (liability-like: credit increases balance)
        end if;
        
        -- Get current balance
        select balance into v_balance
        from data.balances
        where account_id = NEW.credit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert reversal balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.credit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_credit_delta,
            coalesce(v_balance, 0) + v_credit_delta,
            'transaction_update_reversal', v_user_data
        );
        
        -- Then add application entry with new amount
        if v_accounts_info->NEW.credit_account_id::text->>'type' = 'asset_like' then
            v_credit_delta := -NEW.amount; -- Apply the new credit
        else
            v_credit_delta := NEW.amount; -- Apply the new credit
        end if;
        
        -- Get updated balance after reversal
        select balance into v_balance
        from data.balances
        where account_id = NEW.credit_account_id
        order by created_at desc, id desc
        limit 1;
        
        -- Insert application balance entry
        insert into data.balances (
            account_id, transaction_id, ledger_id, 
            previous_balance, delta, balance, 
            operation_type, user_data
        )
        values (
            NEW.credit_account_id, NEW.id, v_ledger_id,
            coalesce(v_balance, 0),
            v_credit_delta,
            coalesce(v_balance, 0) + v_credit_delta,
            'transaction_update_application', v_user_data
        );
    end if;
    
    return NEW;
end;
$$ language plpgsql;

-- function to handle transaction deletes and update balances accordingly
create or replace function utils.handle_transaction_delete_balance()
returns trigger as $$
declare
    v_accounts_info jsonb;
    v_ledger_id bigint := OLD.ledger_id;
    v_user_data text := OLD.user_data;
begin
    -- Get account information and current balances in a single query
    with account_data as (
        select 
            a.id, a.internal_type,
            (select balance from data.balances 
             where account_id = a.id 
             order by created_at desc, id desc limit 1) as current_balance,
            (select delta from data.balances 
             where transaction_id = OLD.id and account_id = a.id and operation_type = 'transaction_insert'
             limit 1) as original_delta
        from 
            data.accounts a
        where 
            a.id in (OLD.debit_account_id, OLD.credit_account_id)
    )
    select 
        jsonb_object_agg(id::text, jsonb_build_object(
            'type', internal_type,
            'balance', coalesce(current_balance, 0),
            'original_delta', original_delta
        )) into v_accounts_info
    from account_data;
    
    -- Insert reversal entries for both accounts in a single statement
    insert into data.balances (
        account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type, user_data
    )
    values 
    (
        OLD.debit_account_id, OLD.id, v_ledger_id,
        (v_accounts_info->OLD.debit_account_id::text->>'balance')::bigint,
        -(v_accounts_info->OLD.debit_account_id::text->>'original_delta')::bigint,
        (v_accounts_info->OLD.debit_account_id::text->>'balance')::bigint - 
        (v_accounts_info->OLD.debit_account_id::text->>'original_delta')::bigint,
        'transaction_delete', v_user_data
    ),
    (
        OLD.credit_account_id, OLD.id, v_ledger_id,
        (v_accounts_info->OLD.credit_account_id::text->>'balance')::bigint,
        -(v_accounts_info->OLD.credit_account_id::text->>'original_delta')::bigint,
        (v_accounts_info->OLD.credit_account_id::text->>'balance')::bigint - 
        (v_accounts_info->OLD.credit_account_id::text->>'original_delta')::bigint,
        'transaction_delete', v_user_data
    );
    
    return OLD;
end;
$$ language plpgsql security definer;

-- function to handle transaction soft deletes and update balances accordingly
create or replace function utils.transactions_after_soft_delete_fn()
returns trigger as $$
declare
    v_accounts_info jsonb;
    v_ledger_id bigint := NEW.ledger_id;
    v_user_data text := NEW.user_data;
begin
    -- Get account information and current balances in a single query
    with account_data as (
        select 
            a.id, a.internal_type,
            (select balance from data.balances 
             where account_id = a.id 
             order by created_at desc, id desc limit 1) as current_balance,
            (select delta from data.balances 
             where transaction_id = NEW.id and account_id = a.id and operation_type = 'transaction_insert'
             limit 1) as original_delta
        from 
            data.accounts a
        where 
            a.id in (NEW.debit_account_id, NEW.credit_account_id)
    )
    select 
        jsonb_object_agg(id::text, jsonb_build_object(
            'type', internal_type,
            'balance', coalesce(current_balance, 0),
            'original_delta', original_delta
        )) into v_accounts_info
    from account_data;
    
    -- Insert reversal entries for both accounts in a single statement
    insert into data.balances (
        account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type, user_data
    )
    values 
    (
        NEW.debit_account_id, NEW.id, v_ledger_id,
        (v_accounts_info->NEW.debit_account_id::text->>'balance')::bigint,
        -(v_accounts_info->NEW.debit_account_id::text->>'original_delta')::bigint,
        (v_accounts_info->NEW.debit_account_id::text->>'balance')::bigint - 
        (v_accounts_info->NEW.debit_account_id::text->>'original_delta')::bigint,
        'transaction_soft_delete', v_user_data
    ),
    (
        NEW.credit_account_id, NEW.id, v_ledger_id,
        (v_accounts_info->NEW.credit_account_id::text->>'balance')::bigint,
        -(v_accounts_info->NEW.credit_account_id::text->>'original_delta')::bigint,
        (v_accounts_info->NEW.credit_account_id::text->>'balance')::bigint - 
        (v_accounts_info->NEW.credit_account_id::text->>'original_delta')::bigint,
        'transaction_soft_delete', v_user_data
    );
    
    return NEW;
end;
$$ language plpgsql security definer;

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
