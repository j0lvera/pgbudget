-- +goose Up
-- +goose StatementBegin

-- creates the accounts table to store different types of accounts for ledgers.
create table data.accounts
(
    id            bigint generated always as identity primary key,
    uuid          text        not null default utils.nanoid(8),

    created_at    timestamptz not null default current_timestamp,
    updated_at    timestamptz not null default current_timestamp,

    name          text        not null,
    description   text,
    type          text        not null,
    internal_type text        not null,
    metadata      jsonb,
    user_data     text        not null default utils.get_user(),

    -- links the account to a ledger. accounts are deleted if the parent ledger is deleted.
    ledger_id     bigint      not null references data.ledgers (id) on delete cascade,

    -- constraints
    constraint accounts_uuid_unique unique (uuid),
    constraint accounts_name_ledger_unique unique (name, ledger_id, user_data),
    constraint accounts_name_length_check check (char_length(name) <= 255),
    constraint accounts_user_data_length_check check (char_length(user_data) <= 255),
    constraint accounts_description_length_check check (char_length(description) <= 255),
    constraint accounts_type_check check (
        type in ('asset', 'liability', 'equity', 'revenue', 'expense')
    ),
    -- ensures 'internal_type' is consistent with 'type'.
    -- 'asset' and 'expense' accounts are 'asset_like' (debits increase balance).
    -- 'liability', 'equity', and 'revenue' accounts are 'liability_like' (credits increase balance).
    constraint accounts_internal_type_check check (
        (type = 'asset' and internal_type = 'asset_like') or
        (type = 'expense' and internal_type = 'asset_like') or
        (type = 'liability' and internal_type = 'liability_like') or
        (type = 'equity' and internal_type = 'liability_like') or
        (type = 'revenue' and internal_type = 'liability_like')
    )
);

comment on table data.accounts is 'Stores accounts for ledgers, such as bank accounts, credit cards, income categories, and budget categories.';
comment on column data.accounts.id is 'Unique internal identifier for the account.';
comment on column data.accounts.uuid is 'Public unique identifier for the account.';
comment on column data.accounts.name is 'User-defined name for the account (e.g., "Checking Account", "Groceries Category").';
comment on column data.accounts.description is 'Optional description for the account.';
comment on column data.accounts.type is 'The accounting type of the account (asset, liability, equity, revenue, expense). Determines its role in financial statements.';
comment on column data.accounts.internal_type is 'The behavioral type of the account (asset_like or liability_like). Determines how debits and credits affect its balance. This is automatically set based on the `type`.';
comment on column data.accounts.metadata is 'Optional JSONB field for storing arbitrary structured data related to the account.';
comment on column data.accounts.user_data is 'Identifier of the user who owns the account, inherited from the ledger.';
comment on column data.accounts.ledger_id is 'Foreign key referencing the ledger this account belongs to.';

-- creates a trigger to automatically update the updated_at timestamp before any update operation on an account.
create trigger accounts_updated_at_tg
    before update
    on data.accounts
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger accounts_updated_at_tg on data.accounts is 'Automatically updates the updated_at timestamp before any update operation on an account.';

-- creates a trigger function in the utils schema to set internal_type based on account type.
create or replace function utils.set_account_internal_type_fn()
    returns trigger as
$$
begin
    -- determine internal_type based on the account's 'type'.
    -- 'asset' and 'expense' types are 'asset_like' (debits increase balance).
    -- 'liability', 'equity', and 'revenue' types are 'liability_like' (credits increase balance).
    if new.type = 'asset' or new.type = 'expense' then
        new.internal_type := 'asset_like';
    else
        new.internal_type := 'liability_like';
    end if;

    return new;
end;
$$ language plpgsql;

comment on function utils.set_account_internal_type_fn() is 'Trigger function to automatically set the `internal_type` of an account based on its `type` before insert or update.';

-- creates a trigger to automatically set internal_type before insert on data.accounts.
create trigger accounts_set_internal_type_tg
    before insert
    on data.accounts
    for each row
execute procedure utils.set_account_internal_type_fn();

comment on trigger accounts_set_internal_type_tg on data.accounts is 'Automatically sets the `internal_type` column based on the `type` column before an account is inserted.';

-- grants privileges on the data.accounts table to the pgb_web_user role.
grant all on data.accounts to pgb_web_user;
-- grants privileges on the sequence for the id column to the pgb_web_user role.
grant usage, select on sequence data.accounts_id_seq to pgb_web_user;

-- enables row level security (rls) on the data.accounts table.
alter table data.accounts
    enable row level security;

-- creates an rls policy on data.accounts to ensure users can only access and modify their own accounts.
create policy accounts_policy on data.accounts
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy accounts_policy on data.accounts is 'Ensures that users can only access and modify their own accounts based on the user_data column.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists accounts_policy on data.accounts;

revoke all on data.accounts from pgb_web_user;
revoke usage, select on sequence data.accounts_id_seq from pgb_web_user;

drop trigger if exists accounts_updated_at_tg on data.accounts;
drop trigger if exists accounts_set_internal_type_tg on data.accounts;
drop function if exists utils.set_account_internal_type_fn();

drop table if exists data.accounts;

-- +goose StatementEnd
