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
-- function to find a category by name in a ledger
create or replace function api.find_category(
    p_ledger_id int,
    p_name text
) returns int as
$$
declare
    v_category_id int;
begin
    -- find the category account for this ledger
    select id into v_category_id
    from data.accounts
    where ledger_id = p_ledger_id
      and name = p_name
      and type = 'equity';
      
    return v_category_id;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose StatementBegin
-- function to get budget status for all categories
create or replace function api.get_budget_status(
    p_ledger_id int
) returns table (
    account_id int,
    account_name text,
    budgeted decimal,
    activity decimal,
    available decimal
) as
$$
begin
    return query
    with category_accounts as (
        -- Get all equity accounts that are categories (not Income or Unassigned)
        select id, name
        from data.accounts
        where ledger_id = p_ledger_id
          and type = 'equity'
          and name not in ('Income', 'Off-budget')
    ),
    budget_transactions as (
        -- Get all transactions where Income is debited (money assigned to categories)
        select 
            t.credit_account_id as category_id,
            sum(t.amount) as budgeted_amount
        from data.transactions t
        join data.accounts a on a.id = t.debit_account_id
        where t.ledger_id = p_ledger_id
          and a.name = 'Income'
        group by t.credit_account_id
    ),
    spending_transactions as (
        -- Get all transactions where categories are debited (money spent from categories)
        select 
            t.debit_account_id as category_id,
            sum(t.amount) * -1 as spent_amount  -- Negative because money is leaving the category
        from data.transactions t
        join category_accounts ca on ca.id = t.debit_account_id
        where t.ledger_id = p_ledger_id
        group by t.debit_account_id
    )
    select 
        ca.id as account_id,
        ca.name as account_name,
        coalesce(bt.budgeted_amount, 0) as budgeted,
        coalesce(st.spent_amount, 0) as activity,
        coalesce(bt.budgeted_amount, 0) + coalesce(st.spent_amount, 0) as available
    from category_accounts ca
    left join budget_transactions bt on bt.category_id = ca.id
    left join spending_transactions st on st.category_id = ca.id
    order by ca.name;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions
drop function if exists api.assign_to_category(int, timestamptz, text, decimal, int);
drop function if exists api.add_category(int, text);
drop function if exists api.get_budget_status(int);
drop function if exists api.find_category(int, text);
-- +goose StatementEnd
