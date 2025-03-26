-- +goose Up
-- +goose StatementBegin
-- Function to create default accounts for a new ledger
CREATE OR REPLACE FUNCTION create_default_ledger_accounts()
RETURNS TRIGGER AS $$
BEGIN
    -- Create Income account (Equity type)
    INSERT INTO accounts (ledger_id, name, type, created_at, updated_at)
    VALUES (NEW.id, 'Income', 'equity', NOW(), NOW());
    
    -- Create Off-budget account (Equity type)
    INSERT INTO accounts (ledger_id, name, type, created_at, updated_at)
    VALUES (NEW.id, 'Off-budget', 'equity', NOW(), NOW());
    
    -- Create Unassigned account (Equity type)
    INSERT INTO accounts (ledger_id, name, type, created_at, updated_at)
    VALUES (NEW.id, 'Unassigned', 'equity', NOW(), NOW());
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to run the function when a new ledger is created
CREATE TRIGGER trigger_create_default_ledger_accounts
AFTER INSERT ON ledgers
FOR EACH ROW
EXECUTE FUNCTION create_default_ledger_accounts();

-- Add constraint to prevent duplicate special accounts per ledger
CREATE UNIQUE INDEX unique_special_accounts_per_ledger
ON accounts (ledger_id, name)
WHERE name IN ('Income', 'Off-budget', 'Unassigned') AND type = 'equity';

-- Add constraint to prevent deletion of special accounts
CREATE OR REPLACE FUNCTION prevent_special_account_deletion()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Cannot delete special account: %', OLD.name;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_prevent_special_account_deletion
BEFORE DELETE ON accounts
FOR EACH ROW
WHEN (OLD.name IN ('Income', 'Off-budget', 'Unassigned') AND OLD.type = 'equity')
EXECUTE FUNCTION prevent_special_account_deletion();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- Remove the triggers and functions
DROP TRIGGER IF EXISTS trigger_prevent_special_account_deletion ON accounts;
DROP FUNCTION IF EXISTS prevent_special_account_deletion();

DROP TRIGGER IF EXISTS trigger_create_default_ledger_accounts ON ledgers;
DROP FUNCTION IF EXISTS create_default_ledger_accounts();

-- Remove the constraint
DROP INDEX IF EXISTS unique_special_accounts_per_ledger;
-- +goose StatementEnd
