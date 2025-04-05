-- +goose Up
-- +goose StatementBegin
create table if not exists data.account_balances
(
    id               bigint generated always as identity primary key,
    created_at       timestamptz not null default current_timestamp,
    updated_at       timestamptz not null default current_timestamp,

    previous_balance bigint      not null,
    balance          bigint      not null,
    -- The amount that changed (can be positive or negative)
    delta            bigint      not null,

    -- Helpful for auditing/debugging
    operation_type   text        not null,

    -- Denormalized references for easier querying
    account_id       bigint      not null references data.accounts (id),
    ledger_id        bigint      not null references data.ledgers (id),
    transaction_id   bigint      not null references data.transactions (id),

    constraint account_balances_operation_type_check check (
        operation_type in ('credit', 'debit')
        ),
    constraint account_balances_delta_valid_check check (
        (operation_type = 'debit' and delta > 0) or
        (operation_type = 'credit' and delta < 0)
        )
);

-- Index for fetching latest balance quickly
create index if not exists account_balances_account_latest_idx
    on data.account_balances (account_id, created_at desc);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table if exists data.account_balances;
drop index if exists data.account_balances_account_latest_idx;
-- +goose StatementEnd
