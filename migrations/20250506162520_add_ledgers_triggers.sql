-- +goose Up
-- +goose StatementBegin

-- Function to create default accounts for a new ledger
create or replace function api.create_default_ledger_accounts()
    returns trigger as
$$
begin
    -- create income account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data, 'Income', 'equity', 'liability_like', current_timestamp, current_timestamp);

    -- create Off-budget account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data,'Off-budget', 'equity', 'liability_like', current_timestamp, current_timestamp);

    -- create Unassigned account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data, 'Unassigned', 'equity', 'liability_like', current_timestamp, current_timestamp);

    return new;
end;
$$ language plpgsql;

comment on function api.create_default_ledger_accounts() is 'Trigger function to automatically create default accounts (Income, Off-budget, Unassigned) when a new ledger is inserted into data.ledgers.';

-- Trigger to run the function when a new ledger is created
create trigger trigger_create_default_ledger_accounts
    after insert
    on data.ledgers
    for each row
execute function api.create_default_ledger_accounts();

comment on trigger trigger_create_default_ledger_accounts on data.ledgers is 'After inserting a new ledger, automatically creates associated default accounts.';

-- Constraint to prevent duplicate special accounts per ledger (acts on data.accounts)
create unique index if not exists unique_special_accounts_per_ledger
    on data.accounts (ledger_id, name)
    where name in ('Income', 'Off-budget', 'Unassigned') and type = 'equity';

comment on index data.unique_special_accounts_per_ledger is 'Ensures that special account names (Income, Off-budget, Unassigned) are unique per ledger for equity type accounts.';

-- Function to prevent deletion of special accounts (acts on data.accounts)
create or replace function api.prevent_special_account_deletion()
    returns trigger as
$$
begin
    raise exception 'Cannot delete special account: %', OLD.name;
    RETURN NULL; -- For BEFORE trigger, returning NULL cancels the operation.
end;
$$ language plpgsql;

comment on function api.prevent_special_account_deletion() is 'Trigger function to prevent the deletion of special accounts (Income, Off-budget, Unassigned).';

-- Trigger to prevent deletion of special accounts (acts on data.accounts)
create trigger trigger_prevent_special_account_deletion
    before delete
    on data.accounts
    for each row
    when (OLD.name in ('Income', 'Off-budget', 'Unassigned') and OLD.type = 'equity')
execute function api.prevent_special_account_deletion();

comment on trigger trigger_prevent_special_account_deletion on data.accounts is 'Prevents deletion of special equity accounts (Income, Off-budget, Unassigned).';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
SELECT 'down SQL query';
-- +goose StatementEnd
