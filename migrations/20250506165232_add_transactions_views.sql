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
    
    -- Using %ROWTYPE ensures the returned row exactly matches the structure of the api.transactions view.
    -- This guarantees type compatibility and prevents structure mismatch errors when the function
    -- is called with a SELECT statement that expects specific columns in a specific order.
    v_transaction_row api.transactions%ROWTYPE;
begin
    -- Call the utils function and store the entire result in a record variable
    select * into v_result from utils.assign_to_category(
        p_ledger_uuid   := p_ledger_uuid,
        p_date          := p_date,
        p_description   := p_description,
        p_amount        := p_amount,
        p_category_uuid := p_category_uuid
    );
    
    -- Construct a single row of api.transactions type
    select 
        v_result.r_uuid::text,
        v_result.r_description::text,
        v_result.r_amount::bigint,
        v_result.r_date::timestamptz,
        v_result.r_metadata::jsonb,
        v_result.r_ledger_uuid::text,
        v_result.r_transaction_type::text,
        v_result.r_account_uuid::text,
        v_result.r_category_uuid::text
    into v_transaction_row;
    
    -- Return the single row
    return next v_transaction_row;
    return;
end;
$$ language plpgsql volatile security invoker;

grant execute on function api.assign_to_category(text, timestamptz, text, bigint, text) to pgb_web_user;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke execute on function api.assign_to_category(text, timestamptz, text, bigint, text) from pgb_web_user;

drop function if exists api.assign_to_category(text, timestamptz, text, bigint, text) cascade;

revoke all on api.transactions from pgb_web_user;

drop view if exists api.transactions;

-- +goose StatementEnd
