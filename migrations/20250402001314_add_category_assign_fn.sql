-- +goose Up
-- +goose StatementBegin
-- function to assign money from Income to a category
create or replace function api.assign_to_category(
    p_ledger_id int,
    p_date timestamptz,
    p_description text,
    p_amount decimal,
    p_category_id int
) returns int as
$$
declare
    v_transaction_id int;
    v_income_id int;
    v_category_ledger_id int;
begin
    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Assignment amount must be positive: %', p_amount;
    end if;

    -- find the Income account for this ledger
    v_income_id := api.find_category(p_ledger_id, 'Income');
    if v_income_id is null then
        raise exception 'Income account not found for ledger %', p_ledger_id;
    end if;

    -- verify category exists and belongs to the specified ledger
    select ledger_id into v_category_ledger_id from data.accounts where id = p_category_id;
    
    if v_category_ledger_id is null then
        raise exception 'Category with ID % not found', p_category_id;
    end if;
    
    if v_category_ledger_id != p_ledger_id then
        raise exception 'Category must belong to the specified ledger (ID %)', p_ledger_id;
    end if;

    -- create the transaction using the existing add_transaction function
    -- this is an outflow from Income to the category
    v_transaction_id := api.add_transaction(
        p_ledger_id,
        p_date,
        p_description,
        'outflow',
        p_amount,
        v_income_id,
        p_category_id
    );

    return v_transaction_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the function
drop function if exists api.assign_to_category(int, timestamptz, text, decimal, int);
-- +goose StatementEnd
