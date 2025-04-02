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

-- +goose StatementBegin
-- function to create a new category account
create or replace function api.add_category(
    p_ledger_id int,
    p_name text
) returns int as
$$
declare
    v_category_id int;
begin
    -- validate the category name is not empty
    if p_name is null or trim(p_name) = '' then
        raise exception 'Category name cannot be empty';
    end if;
    
    -- create the category account (always equity type with liability_like behavior)
    -- the uniqueness constraint on the table will handle duplicate names
    insert into data.accounts (ledger_id, name, type, internal_type)
    values (p_ledger_id, p_name, 'equity', 'liability_like')
    returning id into v_category_id;
    
    return v_category_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose StatementBegin
-- function to create a new account with optional initial balance
create or replace function api.add_account(
    p_ledger_id int,
    p_name text,
    p_type text,
    p_initial_balance decimal default 0
) returns int as
$$
declare
    v_account_id int;
    v_internal_type text;
    v_income_id int;
begin
    -- determine internal type based on account type
    if p_type = 'asset' then
        v_internal_type := 'asset_like';
    else
        v_internal_type := 'liability_like';
    end if;
    
    -- create the account
    insert into data.accounts (ledger_id, name, type, internal_type)
    values (p_ledger_id, p_name, p_type, v_internal_type)
    returning id into v_account_id;
    
    -- if initial balance is provided and not zero, create a transaction to set it
    if p_initial_balance != 0 then
        -- find the Income account for this ledger
        v_income_id := api.find_category(p_ledger_id, 'Income');
        
        if v_income_id is null then
            raise exception 'Income account not found for ledger %', p_ledger_id;
        end if;
        
        -- create initial balance transaction
        if p_type = 'asset' then
            -- for assets: debit the new account, credit Income
            perform api.add_transaction(
                p_ledger_id,
                now(),
                'Initial balance',
                'inflow',
                p_initial_balance,
                v_account_id,
                v_income_id
            );
        else
            -- for liabilities and equity: debit Income, credit the new account
            perform api.add_transaction(
                p_ledger_id,
                now(),
                'Initial balance',
                'outflow',
                p_initial_balance,
                v_income_id,
                v_account_id
            );
        end if;
    end if;
    
    return v_account_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
drop function if exists api.assign_to_category(int, timestamptz, text, decimal, int);
drop function if exists api.add_category(int, text);
drop function if exists api.add_account(int, text, text, decimal);
-- +goose StatementEnd
