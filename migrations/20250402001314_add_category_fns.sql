-- +goose Up
-- +goose StatementBegin

-- function to assign money from Income to a category
create or replace function api.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_id int
) returns int as
$$
declare
    v_ledger_id          int;
    v_transaction_id     int;
    v_income_id          int;
    v_category_ledger_id int;
begin
    -- find the ledger ID for the specified UUID
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Assignment amount must be positive: %', p_amount;
    end if;

    -- find the Income account for this ledger
    v_income_id := utils.find_category(p_ledger_uuid, 'Income');
    if v_income_id is null then
        raise exception 'Income account not found for ledger %', v_ledger_id;
    end if;

    -- verify category exists and belongs to the specified ledger
    select ledger_id into v_category_ledger_id from data.accounts where id = p_category_id;

    if v_category_ledger_id is null then
        raise exception 'Category with ID % not found', p_category_id;
    end if;

    if v_category_ledger_id != v_ledger_id then
        raise exception 'Category must belong to the specified ledger (ID %)', v_ledger_id;
    end if;

    -- create the transaction using the existing add_transaction function
    -- this is an outflow from Income to the category
--     v_transaction_id := api.add_transaction(
--             p_ledger_id,
--             p_date,
--             p_description,
--             'outflow',
--             p_amount,
--             v_income_id,
--             p_category_id
--                         );
--
--     return v_transaction_id;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose StatementBegin

-- function to create a new category account
create or replace function api.add_category(
    p_ledger_uuid text,
    p_name text
) returns int as
$$
declare
    v_ledger_id   int;
    v_category_id int;
begin
    -- find the ledger ID for the specified UUID
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid;

    -- validate the category name is not empty
    if p_name is null or trim(p_name) = '' then
        raise exception 'Category name cannot be empty';
    end if;

    -- create the category account (always equity type with liability_like behavior)
    -- the uniqueness constraint on the table will handle duplicate names
       insert into data.accounts (ledger_id, name, type, internal_type)
       values (v_ledger_id, p_name, 'equity', 'liability_like')
    returning id into v_category_id;

    return v_category_id;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose StatementBegin

-- function to find a category by name in a ledger
create or replace function utils.find_category(
    p_ledger_uuid text,
    p_category_name text,
    p_user_data text = utils.get_user()
) returns int as
$$
declare
    v_ledger_id int;
    v_category_id int;
begin
    -- find the ledger ID for the specified UUID
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid;
     
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found', p_ledger_uuid;
    end if;

    -- find the category account for this ledger
    select a.id
      into v_category_id
      from data.accounts a
     where a.ledger_id = v_ledger_id
       and a.user_data = p_user_data
       and a.name = p_category_name
       and a.type = 'equity';

    return v_category_id;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the functions
drop function if exists api.assign_to_category(text, timestamptz, text, bigint, int);
drop function if exists api.add_category(text, text);
drop function if exists utils.find_category(text, text, text);

-- +goose StatementEnd
