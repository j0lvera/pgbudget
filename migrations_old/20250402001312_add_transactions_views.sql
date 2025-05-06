-- +goose Up
-- +goose StatementBegin

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

-- create the API view for transactions
create or replace view api.transactions with (security_invoker = true) as
select t.uuid,
       t.description,
       t.amount,
       t.metadata,
       t.date,
       (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text          as ledger_uuid,
       (select a.uuid from data.accounts a where a.id = t.debit_account_id)::text  as debit_account_uuid,
       (select a.uuid from data.accounts a where a.id = t.credit_account_id)::text as credit_account_uuid
  from data.transactions t;

-- create the insert trigger for the transactions view
create trigger transactions_insert_tg
    instead of insert
    on api.transactions
    for each row
execute function utils.transactions_insert_single_fn();

-- grant permissions to the web user
grant all on api.transactions to pgb_web_user;

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

-- Create the simple_transactions view
create or replace view api.simple_transactions with (security_invoker = true) as
select
    t.uuid,
    t.description,
    t.amount,
    t.metadata,
    t.date,
    -- Determine transaction type based on account relationships
    case
        when a_debit.internal_type = 'asset_like' and a_debit.id = t.debit_account_id then 'inflow'
        when a_credit.internal_type = 'asset_like' and a_credit.id = t.credit_account_id then 'outflow'
        when a_debit.internal_type = 'liability_like' and a_debit.id = t.debit_account_id then 'outflow'
        when a_credit.internal_type = 'liability_like' and a_credit.id = t.credit_account_id then 'inflow'
    end as type,
    -- Determine which account is the bank/credit card account
    case
        when a_debit.type in ('asset', 'liability') then a_debit.uuid
        when a_credit.type in ('asset', 'liability') then a_credit.uuid
    end as account_uuid,
    -- Determine which account is the category
    case
        when a_debit.type = 'equity' then a_debit.uuid
        when a_credit.type = 'equity' then a_credit.uuid
    end as category_uuid,
    (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text as ledger_uuid
from
    data.transactions t
    join data.accounts a_debit on t.debit_account_id = a_debit.id
    join data.accounts a_credit on t.credit_account_id = a_credit.id;

-- Create triggers for the simple_transactions view
create trigger simple_transactions_insert_tg
    instead of insert
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_insert_fn();

create trigger simple_transactions_update_tg
    instead of update
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_update_fn();

create trigger simple_transactions_delete_tg
    instead of delete
    on api.simple_transactions
    for each row
execute function utils.simple_transactions_delete_fn();

-- Grant permissions to the web user
grant all on api.simple_transactions to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- drop the functions

revoke all on api.transactions from pgb_web_user;
revoke all on api.simple_transactions from pgb_web_user;

drop trigger if exists transactions_insert_tg on api.transactions;
drop trigger if exists simple_transactions_insert_tg on api.simple_transactions;
drop trigger if exists simple_transactions_update_tg on api.simple_transactions;
drop trigger if exists simple_transactions_delete_tg on api.simple_transactions;

drop view if exists api.transactions;
drop view if exists api.simple_transactions;

drop function if exists utils.transactions_insert_single_fn();
drop function if exists utils.simple_transactions_insert_fn();
drop function if exists utils.simple_transactions_update_fn();
drop function if exists utils.simple_transactions_delete_fn();

-- +goose StatementEnd
