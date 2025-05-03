-- +goose Up
-- +goose StatementBegin

-- function to assign money from Income to a category
create or replace function api.assign_to_category(
    p_ledger_id int,
    p_user_data text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_id int
) returns int as
$$
declare
    v_transaction_id     int;
    v_income_id          int;
    v_category_ledger_id int;
begin
    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Assignment amount must be positive: %', p_amount;
    end if;

    -- find the Income account for this ledger
    v_income_id := api.find_category(p_ledger_id, p_user_data, 'Income');
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
            p_user_data,
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
    p_user_data text,
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
       insert into data.accounts (ledger_id, user_data, name, type, internal_type)
       values (p_ledger_id, p_user_data, p_name, 'equity', 'liability_like')
    returning id into v_category_id;

    return v_category_id;
end;
$$ language plpgsql;

-- +goose StatementEnd


-- +goose StatementBegin

-- function to find a category by name in a ledger
create or replace function api.find_category(
    p_ledger_id int,
    p_user_data text,
    p_category_name text
) returns int as
$$
declare
    v_category_id int;
begin
    -- find the category account for this ledger
    select id
      into v_category_id
      from data.accounts
     where ledger_id = p_ledger_id
       and user_data = p_user_data
       and name = p_category_name
       and type = 'equity';

    return v_category_id;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the functions
drop function if exists api.assign_to_category(int, text, timestamptz, text, bigint, int);
drop function if exists api.add_category(int, text, text);
drop function if exists api.find_category(int, text, text);

-- +goose StatementEnd
