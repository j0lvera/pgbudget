-- +goose Up
-- +goose StatementBegin

-- utils function to correct a transaction (internal business logic)
create or replace function utils.correct_transaction(
    p_original_uuid text,
    p_new_type text,
    p_new_account_uuid text,
    p_new_category_uuid text,
    p_new_amount bigint,
    p_new_description text,
    p_new_date date,
    p_reason text default 'Transaction correction'
) returns int as $$
declare
    v_original_tx data.transactions;
    v_ledger_uuid text;
    v_account_id bigint;
    v_category_id bigint;
    v_reversal_id bigint;
    v_correction_id bigint;
    v_debit_account_id bigint;
    v_credit_account_id bigint;
begin
    -- get original transaction
    select t.* into v_original_tx
    from data.transactions t
    where t.uuid = p_original_uuid 
      and t.user_data = utils.get_user();
    
    if v_original_tx.id is null then
        raise exception 'Transaction not found: %', p_original_uuid;
    end if;
    
    -- get ledger uuid
    select l.uuid into v_ledger_uuid
    from data.ledgers l
    where l.id = v_original_tx.ledger_id;
    
    -- resolve account id from uuid
    select id into v_account_id 
    from data.accounts 
    where uuid = p_new_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'Account not found: %', p_new_account_uuid;
    end if;
    
    -- handle category lookup (default to Unassigned if null)
    if p_new_category_uuid is null then
        -- use utils.find_category to get "Unassigned" category UUID
        declare
            v_unassigned_uuid text;
        begin
            select utils.find_category(v_ledger_uuid, 'Unassigned') into v_unassigned_uuid;
            
            if v_unassigned_uuid is null then
                raise exception 'Could not find "Unassigned" category in ledger for current user';
            end if;
            
            -- convert UUID to ID
            select id into v_category_id 
            from data.accounts 
            where uuid = v_unassigned_uuid and user_data = utils.get_user();
        end;
    else
        -- find the specified category
        select id into v_category_id 
        from data.accounts 
        where uuid = p_new_category_uuid and user_data = utils.get_user();
        
        if v_category_id is null then
            raise exception 'Category not found: %', p_new_category_uuid;
        end if;
    end if;
    
    -- determine debit/credit based on transaction type (budgeting logic)
    case p_new_type
        when 'outflow' then
            -- money leaves account, goes to category
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        when 'inflow' then
            -- money enters account, comes from category  
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            raise exception 'Invalid transaction type: %. Must be "inflow" or "outflow"', p_new_type;
    end case;
    
    -- create reversal transaction (opposite of original)
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        v_original_tx.amount,
        'REVERSAL: ' || v_original_tx.description,
        v_original_tx.date,
        v_original_tx.credit_account_id,  -- swap accounts to reverse
        v_original_tx.debit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_reversal_id;
    
    -- create corrected transaction with new values
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        p_new_amount,
        p_new_description,
        p_new_date,
        v_debit_account_id,
        v_credit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_correction_id;
    
    -- record the correction in transaction log
    insert into data.transaction_log (original_transaction_id, reversal_transaction_id, correction_transaction_id, mutation_type, reason)
    values (
        v_original_tx.id,
        v_reversal_id,
        v_correction_id,
        'correction',
        p_reason
    );
    
    return v_correction_id;
end;
$$ language plpgsql security definer;

-- utils function to delete a transaction (internal business logic)
create or replace function utils.delete_transaction(
    p_original_uuid text,
    p_reason text default 'Transaction deleted'
) returns int as $$
declare
    v_original_tx data.transactions;
    v_reversal_id bigint;
begin
    -- get original transaction
    select * into v_original_tx 
    from data.transactions 
    where uuid = p_original_uuid 
      and user_data = utils.get_user();
    
    if v_original_tx.id is null then
        raise exception 'Transaction not found: %', p_original_uuid;
    end if;
    
    -- create reversal transaction to cancel original
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        v_original_tx.amount,
        'DELETED: ' || v_original_tx.description,
        v_original_tx.date,
        v_original_tx.credit_account_id,  -- swap accounts to reverse
        v_original_tx.debit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_reversal_id;
    
    -- record the deletion in transaction log
    insert into data.transaction_log (original_transaction_id, reversal_transaction_id, mutation_type, reason)
    values (
        v_original_tx.id,
        v_reversal_id,
        'deletion',
        p_reason
    );
    
    return v_reversal_id;
end;
$$ language plpgsql security definer;

-- api function to correct a transaction (thin public wrapper)
create or replace function api.correct_transaction(
    p_original_uuid text,
    p_new_type text,
    p_new_account_uuid text,
    p_new_category_uuid text,
    p_new_amount bigint,
    p_new_description text,
    p_new_date date,
    p_reason text default 'Transaction correction'
) returns text as $$
declare
    v_correction_id int;
    v_correction_uuid text;
begin
    -- call utils function to do all the work
    select utils.correct_transaction(
        p_original_uuid,
        p_new_type,
        p_new_account_uuid,
        p_new_category_uuid,
        p_new_amount,
        p_new_description,
        p_new_date,
        p_reason
    ) into v_correction_id;
    
    -- get the uuid of the corrected transaction
    select uuid into v_correction_uuid
    from data.transactions
    where id = v_correction_id;
    
    return v_correction_uuid;
end;
$$ language plpgsql security definer;

-- api function to delete a transaction (thin public wrapper)
create or replace function api.delete_transaction(
    p_original_uuid text,
    p_reason text default 'Transaction deleted'
) returns text as $$
declare
    v_reversal_id int;
    v_reversal_uuid text;
begin
    -- call utils function to do all the work
    select utils.delete_transaction(
        p_original_uuid,
        p_reason
    ) into v_reversal_id;
    
    -- get the uuid of the reversal transaction
    select uuid into v_reversal_uuid
    from data.transactions
    where id = v_reversal_id;
    
    return v_reversal_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.correct_transaction(text, text, text, text, bigint, text, date, text);
drop function if exists api.delete_transaction(text, text);
drop function if exists utils.correct_transaction(text, text, text, text, bigint, text, date, text);
drop function if exists utils.delete_transaction(text, text);

-- +goose StatementEnd