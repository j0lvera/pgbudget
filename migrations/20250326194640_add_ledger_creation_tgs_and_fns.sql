-- +goose Up
-- +goose StatementBegin
-- Function to create default accounts for a new ledger (in api schema)
CREATE OR REPLACE FUNCTION api.create_default_ledger_accounts()
    RETURNS TRIGGER AS
$$
BEGIN
    -- Create Income account (Equity type)
    INSERT INTO data.accounts (ledger_id, user_id, name, type, internal_type, created_at, updated_at)
    VALUES (NEW.id, NEW.user_id, 'Income', 'equity', 'liability_like', NOW(), NOW());

    -- Create Off-budget account (Equity type)
    INSERT INTO data.accounts (ledger_id, user_id, name, type, internal_type, created_at, updated_at)
    VALUES (NEW.id, NEW.user_id,'Off-budget', 'equity', 'liability_like', NOW(), NOW());

    -- Create Unassigned account (Equity type)
    INSERT INTO data.accounts (ledger_id, user_id, name, type, internal_type, created_at, updated_at)
    VALUES (NEW.id, NEW.user_id, 'Unassigned', 'equity', 'liability_like', NOW(), NOW());

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to run the function when a new ledger is created
CREATE TRIGGER trigger_create_default_ledger_accounts
    AFTER INSERT
    ON data.ledgers
    FOR EACH ROW
EXECUTE FUNCTION api.create_default_ledger_accounts();

-- Add constraint to prevent duplicate special accounts per ledger
CREATE UNIQUE INDEX IF NOT EXISTS unique_special_accounts_per_ledger
    ON data.accounts (ledger_id, name)
    WHERE name IN ('Income', 'Off-budget', 'Unassigned') AND type = 'equity';

-- Add constraint to prevent deletion of special accounts (in api schema)
CREATE OR REPLACE FUNCTION api.prevent_special_account_deletion()
    RETURNS TRIGGER AS
$$
BEGIN
    RAISE EXCEPTION 'Cannot delete special account: %', OLD.name;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_prevent_special_account_deletion
    BEFORE DELETE
    ON data.accounts
    FOR EACH ROW
    WHEN (OLD.name IN ('Income', 'Off-budget', 'Unassigned') AND OLD.type = 'equity')
EXECUTE FUNCTION api.prevent_special_account_deletion();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- Remove the triggers and functions
DROP TRIGGER IF EXISTS trigger_prevent_special_account_deletion ON data.accounts;
DROP FUNCTION IF EXISTS api.prevent_special_account_deletion();

DROP TRIGGER IF EXISTS trigger_create_default_ledger_accounts ON data.ledgers;
DROP FUNCTION IF EXISTS api.create_default_ledger_accounts();

-- Remove the constraint
DROP INDEX IF EXISTS data.unique_special_accounts_per_ledger;
-- +goose StatementEnd
