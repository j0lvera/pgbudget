-- +goose Up
-- +goose StatementBegin

create table if not exists data.balances
(
    id               bigint generated always as identity primary key,
    uuid             text        not null default utils.nanoid(8),
    created_at       timestamptz not null default current_timestamp,
    updated_at       timestamptz not null default current_timestamp,
    user_data        text        not null default utils.get_user(),

    previous_balance bigint      not null default 0,
    new_balance      bigint      not null,
    delta            bigint      not null,

    operation_type   text        not null default 'transaction',

    account_id       bigint      not null references data.accounts (id),
    ledger_id        bigint      not null references data.ledgers (id),
    transaction_id   bigint      not null references data.transactions (id),

    constraint balances_uuid_unique unique (uuid),
    constraint balances_operation_type_check check (
        char_length(operation_type) > 0 and char_length(operation_type) <= 50
        ),
    constraint balances_calculation_check check (new_balance = previous_balance + delta),
    constraint balances_user_data_length_check check (char_length(user_data) <= 255)
);

-- index for fetching latest balance quickly
create index if not exists balances_account_latest_idx
    on data.balances (account_id, created_at desc);

-- enable row level security
alter table data.balances
    enable row level security;

create policy balances_policy on data.balances
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop policy
drop policy if exists balances_policy on data.balances;

-- drop table
drop table if exists data.balances;

-- +goose StatementEnd
