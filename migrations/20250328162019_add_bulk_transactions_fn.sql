-- +goose Up
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
    v_result record;
    v_unassigned_categories jsonb = '{}'::jsonb;
begin
    -- start a transaction block to make the operation atomic
    -- (will be automatically committed if the function completes successfully)
    
    -- create a temporary table to store results
    create temporary table temp_results (
        transaction_id int,
        status text,
        message text
    ) on commit drop;
    
    -- pre-fetch unassigned categories for all ledgers in the batch
    -- to avoid repeated lookups
    for v_ledger_id in (
        select distinct (t->>'ledger_id')::int 
        from jsonb_array_elements(p_transactions) as t
    ) loop
        v_unassigned_categories = v_unassigned_categories || 
            jsonb_build_object(
                v_ledger_id::text, 
                api.find_category(v_ledger_id, 'unassigned')
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
            
            -- call the existing add_transaction function
            v_result.transaction_id := api.add_transaction(
                v_ledger_id,
                v_date,
                v_description,
                v_type,
                v_amount,
                v_account_id,
                v_category_id
            );
            
            -- store successful result
            insert into temp_results values (
                v_result.transaction_id,
                'success',
                'Transaction created successfully'
            );
            
        exception when others then
            -- store error result
            insert into temp_results values (
                null,
                'error',
                'Error processing transaction: ' || SQLERRM
            );
        end;
    end loop;
    
    -- return the results
    return query select * from temp_results;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the function if it exists
drop function if exists api.add_bulk_transactions(jsonb);
-- +goose StatementEnd
