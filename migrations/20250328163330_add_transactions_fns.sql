-- +goose Up
-- +goose StatementBegin
-- function to add a transaction
create or replace function api.add_transaction(
    p_ledger_id int,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount decimal,
    p_account_id int, -- the bank account or credit card
    p_category_id int = null -- the category, now optional
) returns int as $$
declare
    v_transaction_id int;
    v_debit_account_id int;
    v_credit_account_id int;
    v_category_id int;
begin
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;
    
    -- handle null category by finding the "unassigned" category
    if p_category_id is null then
        v_category_id := api.find_category(p_ledger_id, 'Unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', p_ledger_id;
        end if;
    else
        v_category_id := p_category_id;
    end if;

    -- determine debit and credit accounts based on transaction type
    if p_type = 'inflow' then
        -- for inflow: debit the account (asset increases), credit the category (equity increases)
        v_debit_account_id := p_account_id;
        v_credit_account_id := v_category_id;
    else
        -- for outflow: debit the category (equity decreases), credit the account (asset decreases)
        v_debit_account_id := v_category_id;
        v_credit_account_id := p_account_id;
    end if;

    -- insert the transaction and return the new id
    insert into data.transactions (
        ledger_id,
        date,
        description,
        debit_account_id,
        credit_account_id,
        amount
    ) values (
        p_ledger_id,
        p_date,
        p_description,
        v_debit_account_id,
        v_credit_account_id,
        p_amount
    ) returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose StatementBegin
-- function to add multiple transactions in a single operation
create or replace function api.add_bulk_transactions(
    p_transactions jsonb
) returns table (
    transaction_id int,
    status text,
    message text
) as $$
declare
    v_transaction jsonb;
    v_ledger_id int;
    v_date timestamptz;
    v_description text;
    v_type text;
    v_amount decimal;
    v_account_id int;
    v_category_id int;
    v_transaction_id int;
    v_unassigned_categories jsonb = '{}'::jsonb;
    v_results jsonb = '[]'::jsonb;
    v_has_error boolean = false;
    v_error_message text;
begin
    -- pre-fetch unassigned categories for all ledgers in the batch
    -- to avoid repeated lookups
    for v_ledger_id in (
        select distinct (t->>'ledger_id')::int 
        from jsonb_array_elements(p_transactions) as t
    ) loop
        v_unassigned_categories = v_unassigned_categories || 
            jsonb_build_object(
                v_ledger_id::text, 
                api.find_category(v_ledger_id, 'Unassigned')
            );
    end loop;
    
    -- process each transaction in the array
    for v_transaction in select * from jsonb_array_elements(p_transactions)
    loop
        begin
            -- extract values from the JSON object
            v_ledger_id := (v_transaction->>'ledger_id')::int;
            v_date := (v_transaction->>'date')::timestamptz;
            v_description := v_transaction->>'description';
            v_type := v_transaction->>'type';
            v_amount := (v_transaction->>'amount')::decimal;
            v_account_id := (v_transaction->>'account_id')::int;
            
            -- category_id is optional
            if v_transaction ? 'category_id' then
                v_category_id := (v_transaction->>'category_id')::int;
            else
                v_category_id := null;
            end if;
            
            -- call the existing add_transaction function and store result directly
            v_transaction_id := api.add_transaction(
                v_ledger_id,
                v_date,
                v_description,
                v_type,
                v_amount,
                v_account_id,
                v_category_id
            );
            
            -- store successful result in our results array
            v_results := v_results || jsonb_build_object(
                'transaction_id', v_transaction_id,
                'status', 'success',
                'message', 'Transaction created successfully'
            );
            
        exception when others then
            -- capture error and set error flag
            v_has_error := true;
            v_error_message := SQLERRM;
            
            -- store error result in our results array
            v_results := v_results || jsonb_build_object(
                'transaction_id', null,
                'status', 'error',
                'message', 'Error processing transaction: ' || v_error_message
            );
            
            -- exit the loop early since we'll be rolling back anyway
            exit;
        end;
    end loop;
    
    -- if there was an error, raise an exception to trigger rollback
    if v_has_error then
        -- Add a note that the entire operation was rolled back
        v_results := v_results || jsonb_build_object(
            'transaction_id', null,
            'status', 'error',
            'message', 'All transactions rolled back due to error'
        );
        
        -- Raise exception to trigger rollback
        raise exception 'Transaction batch failed';
    end if;
    
    -- return the results from our JSON array
    return query 
    select 
        (r->>'transaction_id')::int as transaction_id,
        r->>'status' as status,
        r->>'message' as message
    from jsonb_array_elements(v_results) as r;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions in reverse order
drop function if exists api.add_bulk_transactions(jsonb);
drop function if exists api.add_transaction(int, timestamptz, text, text, decimal, int, int);
-- +goose StatementEnd
