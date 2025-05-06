-- +goose Up
-- +goose StatementBegin

-- function to add a transaction
-- this function abstract the underlying logic of adding a transaction into a more user-friendly API
create or replace function utils.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text = null -- the category, now optional
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
    v_account_internal_type text;
begin
    -- find the ledger_id from uuid
    select l.id into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found', p_ledger_uuid;
    end if;

    -- find the account_id from uuid
    select a.id into v_account_id
      from data.accounts a
     where a.uuid = p_account_uuid and a.ledger_id = v_ledger_id;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', p_account_uuid, p_ledger_uuid;
    end if;

    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    -- handle null category by finding the "unassigned" category
    if p_category_uuid is null then
        v_category_id := utils.find_category(p_ledger_uuid, 'Unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', p_ledger_uuid;
        end if;
    else
        -- find the category_id from uuid
        select c.id into v_category_id
          from data.accounts c
         where c.uuid = p_category_uuid and c.ledger_id = v_ledger_id;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger %', p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- get the account internal_type (asset_like or liability_like)
    select a.internal_type
      into v_account_internal_type
      from data.accounts a
     where a.id = v_account_id;

    -- determine debit and credit accounts based on account internal_type and transaction type
    if v_account_internal_type = 'asset_like' then
        if p_type = 'inflow' then
            -- for inflow to asset_like: debit asset_like (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            -- for outflow from asset_like: debit category (decrease), credit asset_like (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        end if;
    elsif v_account_internal_type = 'liability_like' then
        if p_type = 'inflow' then
            -- for inflow to liability_like: debit category (decrease), credit liability_like (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        else
            -- for outflow from liability_like: debit liability_like (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        end if;
    else
        raise exception 'Account internal_type % is not supported for transactions', v_account_internal_type;
    end if;

    -- insert the transaction and return the new id
       insert into data.transactions (ledger_id,
                                      date,
                                      description,
                                      debit_account_id,
                                      credit_account_id,
                                      amount)
       values (v_ledger_id,
               p_date,
               p_description,
               v_debit_account_id,
               v_credit_account_id,
               p_amount)
    returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql;



-- create a function to handle transaction insertion through the API view
create or replace function utils.transactions_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id         bigint;
    v_debit_account_id  bigint;
    v_credit_account_id bigint;
begin
    -- get the ledger_id for denormalization
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid;

    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', NEW.ledger_uuid;
    end if;

    -- get the debit account id
    select a.id
      into v_debit_account_id
      from data.accounts a
     where a.uuid = NEW.debit_account_uuid
       and a.ledger_id = v_ledger_id;

    if v_debit_account_id is null then
        raise exception 'debit account with uuid % not found in ledger %', NEW.debit_account_uuid, NEW.ledger_uuid;
    end if;

    -- get the credit account id
    select a.id
      into v_credit_account_id
      from data.accounts a
     where a.uuid = NEW.credit_account_uuid
       and a.ledger_id = v_ledger_id;

    if v_credit_account_id is null then
        raise exception 'credit account with uuid % not found in ledger %', NEW.credit_account_uuid, NEW.ledger_uuid;
    end if;

    -- insert the transaction into the transactions table
       insert into data.transactions (description, date, amount, debit_account_id, credit_account_id, ledger_id,
                                      metadata)
       values (NEW.description,
               NEW.date,
               NEW.amount,
               v_debit_account_id,
               v_credit_account_id,
               v_ledger_id,
               NEW.metadata)
    returning uuid, description, amount, metadata, date into
        new.uuid, new.description, new.amount, new.metadata, new.date;

    return new;
end;
$$ language plpgsql;


-- Create a function to handle simple transaction insertion
create or replace function utils.simple_transactions_insert_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_uuid      text;
begin
    -- get the ledger_id for denormalization
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid;

    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', NEW.ledger_uuid;
    end if;

    -- find the account_id from uuid
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- validate transaction type
    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- validate amount is positive
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    -- handle null category by finding the "unassigned" category
    if NEW.category_uuid is null then
        v_category_id := utils.find_category(NEW.ledger_uuid, 'Unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', NEW.ledger_uuid;
        end if;
    else
        -- find the category_id from uuid
        select c.id into v_category_id
          from data.accounts c
         where c.uuid = NEW.category_uuid and c.ledger_id = v_ledger_id;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger %', NEW.category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account internal_type and transaction type
    if v_account_internal_type = 'asset_like' then
        if NEW.type = 'inflow' then
            -- for inflow to asset_like: debit asset_like (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            -- for outflow from asset_like: debit category (decrease), credit asset_like (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        end if;
    elsif v_account_internal_type = 'liability_like' then
        if NEW.type = 'inflow' then
            -- for inflow to liability_like: debit category (decrease), credit liability_like (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        else
            -- for outflow from liability_like: debit liability_like (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        end if;
    else
        raise exception 'Account internal_type % is not supported for transactions', v_account_internal_type;
    end if;

    -- insert the transaction into the transactions table
       insert into data.transactions (description, date, amount, debit_account_id, credit_account_id, ledger_id, metadata)
       values (NEW.description,
               NEW.date,
               NEW.amount,
               v_debit_account_id,
               v_credit_account_id,
               v_ledger_id,
               NEW.metadata)
    returning uuid into v_transaction_uuid;

    -- Return the data for the new row
    select t.uuid,
           t.description,
           t.amount,
           t.metadata,
           t.date,
           NEW.type,
           NEW.account_uuid,
           NEW.category_uuid,
           NEW.ledger_uuid
      into NEW
      from data.transactions t
     where t.uuid = v_transaction_uuid;

    return NEW;
end;
$$ language plpgsql;



-- Create a function to handle simple transaction updates
create or replace function utils.simple_transactions_update_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_id        bigint;
begin
    -- Get the transaction ID
    select t.id
      into v_transaction_id
      from data.transactions t
     where t.uuid = OLD.uuid;

    if v_transaction_id is null then
        raise exception 'Transaction with UUID % not found', OLD.uuid;
    end if;

    -- get the ledger_id for denormalization
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid;

    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', NEW.ledger_uuid;
    end if;

    -- find the account_id from uuid
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- validate transaction type
    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- validate amount is positive
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    -- handle null category by finding the "unassigned" category
    if NEW.category_uuid is null then
        v_category_id := utils.find_category(NEW.ledger_uuid, 'Unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', NEW.ledger_uuid;
        end if;
    else
        -- find the category_id from uuid
        select c.id into v_category_id
          from data.accounts c
         where c.uuid = NEW.category_uuid and c.ledger_id = v_ledger_id;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger %', NEW.category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account internal_type and transaction type
    if v_account_internal_type = 'asset_like' then
        if NEW.type = 'inflow' then
            -- for inflow to asset_like: debit asset_like (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            -- for outflow from asset_like: debit category (decrease), credit asset_like (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        end if;
    elsif v_account_internal_type = 'liability_like' then
        if NEW.type = 'inflow' then
            -- for inflow to liability_like: debit category (decrease), credit liability_like (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        else
            -- for outflow from liability_like: debit liability_like (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        end if;
    else
        raise exception 'Account internal_type % is not supported for transactions', v_account_internal_type;
    end if;

    -- Update the transaction
    update data.transactions
       set description = NEW.description,
           date = NEW.date,
           amount = NEW.amount,
           debit_account_id = v_debit_account_id,
           credit_account_id = v_credit_account_id,
           metadata = NEW.metadata
     where id = v_transaction_id;

    return NEW;
end;
$$ language plpgsql;


-- Create a function to handle simple transaction deletions
create or replace function utils.simple_transactions_delete_fn() returns trigger as
$$
begin
    -- Delete the transaction
    delete from data.transactions
     where uuid = OLD.uuid;

    return OLD;
end;
$$ language plpgsql;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.add_transaction(text, timestamptz, text, text, bigint, text, text);

drop function if exists utils.transactions_insert_single_fn();

-- +goose StatementEnd
