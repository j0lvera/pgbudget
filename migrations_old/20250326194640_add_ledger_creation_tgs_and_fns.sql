-- +goose Up
-- +goose StatementBegin

-- create function that creates default accounts for a new ledger (in api schema)
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

-- create trigger to run the function when a new ledger is created
create trigger trigger_create_default_ledger_accounts
    after insert
    on data.ledgers
    for each row
execute function api.create_default_ledger_accounts();

-- add constraint to prevent duplicate special accounts per ledger
create unique index if not exists unique_special_accounts_per_ledger
    on data.accounts (ledger_id, name)
    where name in ('Income', 'Off-budget', 'Unassigned') and type = 'equity';

-- add constraint to prevent deletion of special accounts (in api schema)
create or replace function api.prevent_special_account_deletion()
    returns trigger as
$$
begin
    raise exception 'Cannot delete special account: %', OLD.name;
    RETURN NULL;
end;
$$ language plpgsql;

create trigger trigger_prevent_special_account_deletion
    before delete
    on data.accounts
    for each row
    when (OLD.name in ('Income', 'Off-budget', 'Unassigned') and OLD.type = 'equity')
execute function api.prevent_special_account_deletion();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- remove the triggers and functions
drop trigger if exists trigger_prevent_special_account_deletion on data.accounts;
drop function if exists api.prevent_special_account_deletion();

drop trigger if exists trigger_create_default_ledger_accounts on data.ledgers;
drop function if exists api.create_default_ledger_accounts();

-- remove the constraint
drop index if exists data.unique_special_accounts_per_ledger;

-- +goose StatementEnd
