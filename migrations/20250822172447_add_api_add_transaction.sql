-- +goose Up
-- +goose StatementBegin

-- public api function to add a transaction (calls utils function)
-- this provides a stable public interface while allowing internal changes
create or replace function api.add_transaction(
    p_ledger_uuid text,
    p_date date,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text default null -- the category, optional
) returns text as $$
declare
    v_transaction_id int;
    v_transaction_uuid text;
begin
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be "inflow" or "outflow"', p_type;
    end if;
    
    -- call the utils function
    select utils.add_transaction(
        p_ledger_uuid,
        p_date::timestamptz,
        p_description,
        p_type,
        p_amount,
        p_account_uuid,
        p_category_uuid
    ) into v_transaction_id;
    
    -- get the uuid of the created transaction
    select uuid into v_transaction_uuid
    from data.transactions
    where id = v_transaction_id;
    
    return v_transaction_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.add_transaction(text, date, text, text, bigint, text, text);

-- +goose StatementEnd
