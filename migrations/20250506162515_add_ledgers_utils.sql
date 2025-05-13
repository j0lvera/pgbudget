-- +goose Up
-- +goose StatementBegin

-- Function to create default accounts for a new ledger
create or replace function utils.create_default_ledger_accounts()
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

comment on function utils.create_default_ledger_accounts() is 'Trigger function to automatically create default accounts (Income, Off-budget, Unassigned) when a new ledger is inserted into data.ledgers.';

-- Function to prevent deletion of special accounts (acts on data.accounts)
create or replace function utils.prevent_special_account_deletion()
    returns trigger as
$$
begin
    raise exception 'Cannot delete special account: %', OLD.name;
    RETURN NULL; -- For BEFORE trigger, returning NULL cancels the operation.
end;
$$ language plpgsql;

comment on function utils.prevent_special_account_deletion() is 'Trigger function to prevent the deletion of special accounts (Income, Off-budget, Unassigned).';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists utils.prevent_special_account_deletion();

drop function if exists utils.create_default_ledger_accounts();

-- +goose StatementEnd
