-- +goose Up
-- +goose StatementBegin

-- Trigger for data.transactions table (internal audit timestamp)
create trigger transactions_updated_at_tg
    before update
    on data.transactions
    for each row
execute procedure utils.set_updated_at_fn();


-- Create or replace the simple_transactions_update_fn function
create or replace function utils.simple_transactions_update_fn()
returns trigger as $$
declare
    v_ledger_id bigint;
    v_account_id bigint;
    v_category_id bigint;
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the existing transaction record
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = old.uuid and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', old.uuid;
    end if;
    
    -- Resolve ledger_uuid to internal ledger_id
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = new.ledger_uuid and l.user_data = v_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', new.ledger_uuid;
    end if;
    
    -- Validate amount
    if new.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', new.amount;
    end if;
    
    -- Validate transaction type
    if new.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', new.type;
    end if;
    
    -- Resolve account_uuid to internal account_id
    select a.id into v_account_id
    from data.accounts a
    where a.uuid = new.account_uuid and a.ledger_id = v_ledger_id and a.user_data = v_user_data;
    
    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', new.account_uuid, new.ledger_uuid;
    end if;
    
    -- Resolve category_uuid to internal category_id
    select a.id into v_category_id
    from data.accounts a
    where a.uuid = new.category_uuid and a.ledger_id = v_ledger_id and a.user_data = v_user_data;
    
    if v_category_id is null then
        raise exception 'Category with UUID % not found in ledger %', new.category_uuid, new.ledger_uuid;
    end if;
    
    -- Update the transaction based on type
    if new.type = 'inflow' then
        update data.transactions t
        set 
            description = new.description,
            date = new.date,
            amount = new.amount,
            metadata = new.metadata,
            ledger_id = v_ledger_id,
            debit_account_id = v_account_id,
            credit_account_id = v_category_id,
            updated_at = current_timestamp
        where t.uuid = old.uuid and t.user_data = v_user_data
        returning * into v_transaction_record;
    else -- outflow
        update data.transactions t
        set 
            description = new.description,
            date = new.date,
            amount = new.amount,
            metadata = new.metadata,
            ledger_id = v_ledger_id,
            debit_account_id = v_category_id,
            credit_account_id = v_account_id,
            updated_at = current_timestamp
        where t.uuid = old.uuid and t.user_data = v_user_data
        returning * into v_transaction_record;
    end if;
    
    -- Populate the NEW record with values from the updated transaction
    new.uuid := v_transaction_record.uuid;
    new.description := v_transaction_record.description;
    new.amount := v_transaction_record.amount;
    new.date := v_transaction_record.date;
    new.metadata := v_transaction_record.metadata;
    new.ledger_uuid := new.ledger_uuid; -- Already set
    new.account_uuid := new.account_uuid; -- Already set
    new.category_uuid := new.category_uuid; -- Already set
    new.type := new.type; -- Already set
    
    return new;
end;
$$ language plpgsql volatile security definer;

-- Create or replace the simple_transactions_delete_fn function
create or replace function utils.simple_transactions_delete_fn()
returns trigger as $$
declare
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the transaction record
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = old.uuid and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', old.uuid;
    end if;
    
    -- Perform soft delete by setting deleted_at
    update data.transactions
    set deleted_at = current_timestamp
    where uuid = old.uuid and user_data = v_user_data;
    
    return old;
end;
$$ language plpgsql volatile security definer;

-- Triggers for the NEW api.transactions view (which was api.simple_transactions)
-- These are renamed from simple_transactions_*_tg and now target api.transactions
create trigger transactions_insert_tg -- RENAMED from simple_transactions_insert_tg
    instead of insert
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_insert_fn(); -- Calls the simple util

create trigger transactions_update_tg -- RENAMED from simple_transactions_update_tg
    instead of update
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_update_fn(); -- Calls the simple util

create trigger transactions_delete_tg -- RENAMED from simple_transactions_delete_tg
    instead of delete
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_delete_fn(); -- Calls the simple util

-- Create or replace the api.transactions view to exclude soft-deleted transactions
-- create or replace view api.transactions with (security_invoker = true) as
-- select
--     t.uuid,
--     t.description,
--     t.amount,
--     t.date,
--     t.metadata,
--     l.uuid as ledger_uuid,
--     case
--         when t.debit_account_id = a_asset.id then 'inflow'
--         else 'outflow'
--     end as type,
--     case
--         when t.debit_account_id = a_asset.id then a_asset.uuid
--         else a_category.uuid
--     end as account_uuid,
--     case
--         when t.debit_account_id = a_asset.id then a_category.uuid
--         else a_asset.uuid
--     end as category_uuid
-- from
--     data.transactions t
-- join
--     data.ledgers l on t.ledger_id = l.id
-- join
--     data.accounts a_asset on (
--         (t.debit_account_id = a_asset.id and a_asset.type = 'asset') or
--         (t.credit_account_id = a_asset.id and a_asset.type = 'asset')
--     )
-- join
--     data.accounts a_category on (
--         (t.debit_account_id = a_category.id and a_category.type = 'equity') or
--         (t.credit_account_id = a_category.id and a_category.type = 'equity')
--     )
-- where
--     t.deleted_at is null; -- Exclude soft-deleted transactions

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin


-- First drop the triggers on the current api.transactions view
drop trigger if exists transactions_delete_tg on api.transactions;
drop trigger if exists transactions_update_tg on api.transactions;
drop trigger if exists transactions_insert_tg on api.transactions;

drop function if exists utils.simple_transactions_delete_fn();
drop function if exists utils.simple_transactions_update_fn();

-- Drop trigger from data.transactions table
drop trigger if exists transactions_updated_at_tg on data.transactions;


-- Now drop the view
-- drop view if exists api.transactions;

-- +goose StatementEnd
