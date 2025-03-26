-- +goose Up
-- +goose StatementBegin
create table data.accounts
(
    id            bigint generated always as identity primary key,

    created_at    timestamptz not null default current_timestamp,
    updated_at    timestamptz not null default current_timestamp,

    name          text        not null,
    description   text,
    type          text        not null,
    internal_type text        not null,
    metadata      jsonb,

    ledger_id     bigint      not null references data.ledgers (id) on delete cascade,

    constraint accounts_name_unique unique (name, ledger_id),
    constraint accounts_name_length_check check (char_length(name) <= 255),
    constraint accounts_description_length_check check (char_length(description) <= 255),
    constraint accounts_type_check check (
        type in ('asset', 'liability', 'equity', 'revenue', 'expense')
    ),
    constraint accounts_internal_type_check check (
        (type = 'asset' and internal_type = 'asset_like') or
        (type = 'expenses' and internal_type = 'asset_like') or
        (type = 'liability' and internal_type = 'liability_like') or
        (type = 'equity' and internal_type = 'liability_like') or
        (type = 'revenue' and internal_type = 'liability_like')
    )
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table data.accounts;
-- +goose StatementEnd
