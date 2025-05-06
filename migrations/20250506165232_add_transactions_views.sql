-- +goose Up
-- +goose StatementBegin

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

-- grant permissions to the web user
grant select, insert, update, delete on api.transactions to pgb_web_user;

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

grant select, insert, update, delete on api.simple_transactions to pgb_web_user;


-- function to assign money from Income to a category (public API)
-- wrapper around the utils function, handles API input/output formatting
create or replace function api.assign_to_category(
    -- Use p_ prefix for input parameters to avoid collision with return type columns
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
)
returns table ( -- MODIFIED RETURN TYPE
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
    v_util_result record; -- To store the result from utils.assign_to_category (transaction_uuid, income_account_uuid, metadata)
begin
    -- Call the internal utility function
    select * into v_util_result from utils.assign_to_category(
            p_ledger_uuid   := p_ledger_uuid, -- Pass renamed params
            p_date          := p_date,
            p_description   := p_description,
            p_amount        := p_amount,
            p_category_uuid := p_category_uuid
        -- p_user_data defaults to utils.get_user()
                                     );

    -- Return the result by selecting directly from the utils function output
    -- and combining with input parameters.
    -- Use explicit casts and aliases matching the defined table columns.
    return query
        select
            v_util_result.transaction_uuid::text as uuid,
            p_description::text as description, -- Use input param directly
            p_amount::bigint as amount,         -- Use input param directly
            v_util_result.metadata::jsonb as metadata, -- From utils result
            p_date::timestamptz as date,         -- Use input param directly
            p_ledger_uuid::text as ledger_uuid, -- Use input param directly
            v_util_result.income_account_uuid::text as debit_account_uuid, -- From utils result
            p_category_uuid::text as credit_account_uuid; -- Use input param directly

end;
$$ language plpgsql volatile security invoker; -- Runs as the calling user

grant execute on function api.assign_to_category(text, timestamptz, text, bigint, text) to pgb_web_user;


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

revoke all on api.transactions from pgb_web_user;
revoke all on api.simple_transactions from pgb_web_user;

revoke execute on function api.assign_to_category(text, timestamptz, text, bigint, text) from pgb_web_user;
drop function if exists api.assign_to_category(text, timestamptz, text, bigint, text) cascade;

drop view if exists api.transactions;
drop view if exists api.simple_transactions;

-- +goose StatementEnd
