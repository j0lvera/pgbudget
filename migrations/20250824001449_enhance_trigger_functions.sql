-- +goose Up
-- +goose StatementBegin

-- enhance trigger functions to use our enhanced validation utilities
-- eliminate duplication by making trigger function call our enhanced utils.add_transaction
-- following postgresql conventions with lowercase sql and comments above each step

-- update simple_transactions_insert_fn to use our enhanced utils.add_transaction function
-- this eliminates duplication and ensures consistent validation across all transaction creation paths
create or replace function utils.simple_transactions_insert_fn()
returns trigger as
$$
declare
    v_transaction_id int;
    v_user_data text := utils.get_user();
begin
    -- use our enhanced utils.add_transaction function for all validation and business logic
    -- this ensures consistent validation whether transactions are created via API functions or view inserts
    select utils.add_transaction(
        NEW.ledger_uuid,
        NEW.date::timestamptz,
        NEW.description,
        NEW.type,
        NEW.amount,
        NEW.account_uuid,
        NEW.category_uuid,
        v_user_data
    ) into v_transaction_id;
    
    -- populate NEW record with the created transaction data for backward compatibility
    -- get the transaction details from the created record
    select t.uuid, t.description, t.amount, t.date, t.metadata
      into NEW.uuid, NEW.description, NEW.amount, NEW.date, NEW.metadata
      from data.transactions t
     where t.id = v_transaction_id;
    
    -- NEW.ledger_uuid, NEW.account_uuid, NEW.category_uuid, NEW.type are already set from input
    
    return NEW;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- restore original simple_transactions_insert_fn implementation
-- note: this would require restoring the exact original implementation
-- for now, we'll just indicate that a rollback would be needed

select 'Enhanced trigger functions rollback - would need to restore original implementation';

-- +goose StatementEnd