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

-- grants privileges on the data.accounts table to the pgb_web_user role.
grant select, insert, update, delete on data.accounts to pgb_web_user;
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

drop table if exists data.accounts;

-- +goose StatementEnd
