-- +goose Up
-- +goose StatementBegin

-- enhance existing functions with improved error handling
-- following postgresql conventions with lowercase sql and comments above each step

-- enhance utils.add_category function with better error handling
create or replace function utils.add_category(
    p_ledger_uuid text,
    p_name text,
    p_user_data text = utils.get_user()
) returns data.accounts as
$$
declare
    v_ledger_id int;
    v_account_record data.accounts;
    v_cleaned_name text;
begin
    -- validate and clean input data using new utility function
    v_cleaned_name := utils.validate_input_data(p_name, null, 'category');
    
    -- find the ledger ID for the specified UUID and user
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- create the category account (equity type, liability_like behavior)
    -- associate it with the user using user_data
    begin
        insert into data.accounts (ledger_id, name, type, internal_type, user_data)
        values (v_ledger_id, v_cleaned_name, 'equity', 'liability_like', p_user_data)
        returning * into v_account_record;
    exception
        when unique_violation then
            -- use new error handling utility for user-friendly message
            raise exception using 
                message = utils.handle_constraint_violation('accounts_name_ledger_unique', 'accounts', v_cleaned_name),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid ledger reference. Please verify the ledger exists.';
    end;

    return v_account_record;
end;
$$ language plpgsql security definer;

-- enhance utils.add_transaction function with better validation and error handling
create or replace function utils.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text,
    p_amount bigint,
    p_account_uuid text,
    p_category_uuid text = null,
    p_user_data text = utils.get_user()
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_account_internal_type text;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
    v_cleaned_description   text;
begin
    -- validate transaction data using new utility function
    perform utils.validate_transaction_data(p_amount, p_date, p_type);
    
    -- validate and clean description
    v_cleaned_description := coalesce(trim(p_description), '');
    if char_length(v_cleaned_description) > 500 then
        raise exception 'Transaction description cannot exceed 500 characters. Current length: %', 
            char_length(v_cleaned_description);
    end if;

    -- find the ledger_id from uuid and validate ownership
    select l.id into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the account_id and internal_type in one query
    select a.id, a.internal_type 
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = p_account_uuid 
       and a.ledger_id = v_ledger_id
       and a.user_data = p_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       p_account_uuid, p_ledger_uuid;
    end if;

    -- handle category lookup with enhanced error handling
    if p_category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Default "Unassigned" category not found in ledger %. This indicates a system error.', 
                p_ledger_uuid;
        end if;
    else
        -- find the category by UUID
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = p_category_uuid
           and a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.type = 'equity';

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- validate account type and transaction type combination
    if (v_account_internal_type = 'asset_like' and p_type = 'outflow') or
       (v_account_internal_type = 'liability_like' and p_type = 'inflow') then
        -- debit category, credit account
        v_debit_account_id := v_category_id;
        v_credit_account_id := v_account_id;
    elsif (v_account_internal_type = 'asset_like' and p_type = 'inflow') or
          (v_account_internal_type = 'liability_like' and p_type = 'outflow') then
        -- debit account, credit category
        v_debit_account_id := v_account_id;
        v_credit_account_id := v_category_id;
    else
        raise exception 'Invalid combination: account type "%" with transaction type "%". Please verify your account and transaction types.', 
            v_account_internal_type, p_type;
    end if;

    -- create the transaction with enhanced error handling
    begin
        insert into data.transactions (
            ledger_id, description, date, amount,
            debit_account_id, credit_account_id, user_data
        )
        values (
            v_ledger_id, v_cleaned_description, p_date, p_amount,
            v_debit_account_id, v_credit_account_id, p_user_data
        )
        returning id into v_transaction_id;
    exception
        when unique_violation then
            raise exception using 
                message = utils.handle_constraint_violation('transactions_uuid_unique', 'transactions'),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid account reference in transaction. Please verify all accounts exist.';
        when check_violation then
            raise exception 'Transaction violates business rules. Please check amount and account constraints.';
    end;

    return v_transaction_id;
end;
$$ language plpgsql security definer;

-- enhance utils.assign_to_category function with better validation
-- keep the original return type to avoid breaking changes
create or replace function utils.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text,
    p_user_data text = utils.get_user()
) returns table(r_uuid text, r_description text, r_amount bigint, r_date timestamptz, r_metadata jsonb, r_ledger_uuid text, r_transaction_type text, r_account_uuid text, r_category_uuid text) as
$$
declare
    v_ledger_id          int;
    v_income_account_id  int;
    v_income_account_uuid text;
    v_category_account_id int;
    v_transaction_uuid text;
    v_metadata jsonb;
    v_transaction_record data.transactions;
    v_cleaned_description text;
begin
    -- validate assignment amount and date using new utility function
    perform utils.validate_transaction_data(p_amount, p_date);
    
    -- validate and clean description
    v_cleaned_description := coalesce(trim(p_description), '');
    if char_length(v_cleaned_description) > 500 then
        raise exception 'Assignment description cannot exceed 500 characters. Current length: %', 
            char_length(v_cleaned_description);
    end if;

    -- find the ledger ID for the specified UUID and user
    select l.id into v_ledger_id from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the Income account ID and UUID for this ledger
    select a.id, a.uuid into v_income_account_id, v_income_account_uuid 
    from data.accounts a
    where a.ledger_id = v_ledger_id 
      and a.user_data = p_user_data 
      and a.name = 'Income' 
      and a.type = 'equity';
      
    if v_income_account_id is null then
        raise exception 'Income account not found for ledger %. This indicates a system error.', p_ledger_uuid;
    end if;

    -- find the target category account ID with enhanced validation
    select a.id into v_category_account_id from data.accounts a
    where a.uuid = p_category_uuid 
      and a.ledger_id = v_ledger_id 
      and a.user_data = p_user_data 
      and a.type = 'equity';
      
    if v_category_account_id is null then
        raise exception 'Category with UUID % not found in ledger % for current user', 
            p_category_uuid, p_ledger_uuid;
    end if;

    -- create the assignment transaction (debit Income, credit Category)
    begin
        insert into data.transactions (ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data)
        values (v_ledger_id, v_cleaned_description, p_date, p_amount, v_income_account_id, v_category_account_id, p_user_data)
        returning * into v_transaction_record;
    exception
        when unique_violation then
            raise exception using 
                message = utils.handle_constraint_violation('transactions_uuid_unique', 'transactions'),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid account reference in assignment. Please verify all accounts exist.';
    end;

    -- extract values for return
    v_transaction_uuid := v_transaction_record.uuid;
    v_metadata := v_transaction_record.metadata;

    -- return the transaction details in the expected format
    return query select 
        v_transaction_uuid,
        v_cleaned_description,
        p_amount,
        p_date,
        v_metadata,
        p_ledger_uuid,
        null::text, -- transaction_type is null for budget assignments
        v_income_account_uuid,
        p_category_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- restore original function implementations
-- note: this would require restoring the exact original implementations
-- for now, we'll just indicate that a rollback would be needed

select 'Enhanced functions rollback - would need to restore original implementations';

-- +goose StatementEnd
