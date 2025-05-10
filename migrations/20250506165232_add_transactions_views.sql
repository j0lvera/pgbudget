-- +goose Up
-- +goose StatementBegin

-- This view is the primary interface for transactions.
-- It was formerly api.simple_transactions and is designed for simplified transaction entry.
-- The underlying double-entry logic is handled by INSTEAD OF triggers
-- calling utils.simple_transactions_*_fn functions.
create or replace view api.transactions with (security_invoker = true) as
select
    t.uuid,
    t.description,
    t.amount, -- This is the absolute amount of the transaction
    t.date,
    t.metadata,
    l.uuid as ledger_uuid,
    -- The following columns are primarily for the INSERT/UPDATE payload via the view.
    -- For SELECTs, their values might not be directly derivable from a single data.transactions row
    -- without knowing which account was the 'primary' one and which was the 'category' in the simplified model.
    -- The utils.simple_transactions_insert_fn populates these in the NEW record it returns.
    -- For direct SELECTs, these might need more complex logic or be NULL if not easily determined.
    -- For simplicity in SELECT, we'll make them NULL-able or derive if straightforward.
    -- The trigger functions are responsible for interpreting these from the NEW record on INSERT/UPDATE.
    null::text as type, -- Placeholder: The trigger function expects NEW.type ('inflow'/'outflow')
    null::text as account_uuid, -- Placeholder: The trigger function expects NEW.account_uuid
    null::text as category_uuid -- Placeholder: The trigger function expects NEW.category_uuid
from
    data.transactions t
    join data.ledgers l on t.ledger_id = l.id;
    -- Note: The actual values for account_uuid, category_uuid, and type for display (SELECT)
    -- would require reverse-engineering the logic from utils.simple_transactions_insert_fn
    -- or storing additional denormalized fields. For an updatable view, PostgREST primarily cares
    -- about the columns available in NEW for INSERT/UPDATE. The SELECT part of the view
    -- should ideally be consistent, but can be simpler if the primary use is mutation via triggers.
    -- The trigger functions will populate these fields in the returned NEW record.

grant select, insert, update, delete on api.transactions to pgb_web_user;


-- function to assign money from Income to a category (public API)
-- This function provides a public interface for budget allocations
-- It simply passes through to the utils function which handles all the logic
create or replace function api.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
)
returns SETOF api.transactions as
$$
declare
    v_result record;
begin
    -- Call the utils function and store the entire result in a record variable
    select * into v_result from utils.assign_to_category(
        p_ledger_uuid   := p_ledger_uuid,
        p_date          := p_date,
        p_description   := p_description,
        p_amount        := p_amount,
        p_category_uuid := p_category_uuid
    );
    
    -- Return a single row with explicit column aliases to match the test's expected order
    -- Order must match the order in the test: uuid, description, amount, metadata, date, ledger_uuid, type, account_uuid, category_uuid
    return query
    select 
        v_result.result_uuid::text as uuid,
        v_result.result_description::text as description,
        v_result.result_amount::bigint as amount,
        v_result.result_metadata::jsonb as metadata,
        v_result.result_date::timestamptz as date,
        v_result.result_ledger_uuid::text as ledger_uuid,
        v_result.result_transaction_type::text as type,
        v_result.result_account_uuid::text as account_uuid,
        v_result.result_category_uuid::text as category_uuid;
end;
$$ language plpgsql volatile security invoker;

grant execute on function api.assign_to_category(text, timestamptz, text, bigint, text) to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Revoke permissions first
revoke all on api.transactions from pgb_web_user;
revoke execute on function api.assign_to_category(text, timestamptz, text, bigint, text) from pgb_web_user;

-- Drop the new api.transactions view (which was the simplified one)
drop view if exists api.transactions;
-- Drop the api.assign_to_category function
drop function if exists api.assign_to_category(text, timestamptz, text, bigint, text) cascade;

-- Recreate the ORIGINAL api.transactions view (manual double-entry, from ARCHITECTURE.md)
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
grant select, insert, update, delete on api.transactions to pgb_web_user; -- Assuming it had these grants before

-- Recreate the ORIGINAL api.simple_transactions view
-- The definition must match what it was before this migration's "Up" was applied.
create or replace view api.simple_transactions with (security_invoker = true) as
select
    t.uuid,
    t.description,
    t.amount,
    t.date,
    t.metadata,
    l.uuid as ledger_uuid,
    -- These columns are for the INSERT/UPDATE payload for the triggers.
    -- For SELECT, they are placeholders.
    null::text as type, -- 'inflow'/'outflow'
    null::text as account_uuid,
    null::text as category_uuid
from
    data.transactions t
    join data.ledgers l on t.ledger_id = l.id;
grant select, insert, update, delete on api.simple_transactions to pgb_web_user; -- Assuming it had these grants

-- Recreate the api.assign_to_category function (as it was part of the state before this Up)
-- This assumes it was defined exactly like this before this migration.
-- If it was defined in a different migration, this might be redundant or need adjustment
-- based on the actual previous state.
create or replace function api.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
)
returns table (
    uuid text,
    description text,
    amount bigint,
    metadata jsonb,
    date timestamptz,
    ledger_uuid text,
    debit_account_uuid text,
    credit_account_uuid text
) as
$$
declare
    v_util_result record;
begin
    select * into v_util_result from utils.assign_to_category(
            p_ledger_uuid   := p_ledger_uuid,
            p_date          := p_date,
            p_description   := p_description,
            p_amount        := p_amount,
            p_category_uuid := p_category_uuid
                                     );
    return query
        select
            v_util_result.transaction_uuid::text as uuid,
            p_description::text as description,
            p_amount::bigint as amount,
            v_util_result.metadata::jsonb as metadata,
            p_date::timestamptz as date,
            p_ledger_uuid::text as ledger_uuid,
            v_util_result.income_account_uuid::text as debit_account_uuid,
            p_category_uuid::text as credit_account_uuid;
end;
$$ language plpgsql volatile security invoker;
grant execute on function api.assign_to_category(text, timestamptz, text, bigint, text) to pgb_web_user;

-- +goose StatementEnd
