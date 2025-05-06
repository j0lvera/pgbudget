-- +goose Up
-- +goose StatementBegin

create table if not exists data.balances
(
    id               bigint generated always as identity primary key,
    uuid             text        not null default utils.nanoid(8),
    created_at       timestamptz not null default current_timestamp,
    updated_at       timestamptz not null default current_timestamp,
    user_data        text        not null default utils.get_user(),

    previous_balance bigint      not null,
    balance          bigint      not null,
    -- the amount that changed (can be positive or negative)
    delta            bigint      not null,

    -- helpful for auditing/debugging
    operation_type   text        not null,

    -- denormalized references for easier querying
    account_id       bigint      not null references data.accounts (id),
    ledger_id        bigint      not null references data.ledgers (id),
    transaction_id   bigint      not null references data.transactions (id),

    constraint balances_uuid_unique unique (uuid),
    constraint balances_operation_type_check check (
        operation_type in ('credit', 'debit')
        ),
    constraint balances_delta_valid_check check (
        (operation_type = 'debit' and delta > 0) or
        (operation_type = 'credit' and delta < 0)
        ),
    constraint balances_user_data_length_check check (char_length(user_data) <= 255)
);

-- index for fetching latest balance quickly
create index if not exists balances_account_latest_idx
    on data.balances (account_id, created_at desc);

-- grant permissions to pgb_web_user
grant select, insert, update, delete on data.balances to pgb_web_user;
grant usage, select on sequence data.balances_id_seq to pgb_web_user;

-- enable row level security
alter table data.balances
    enable row level security;

create policy balances_policy on data.balances
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists balances_policy on data.balances;

revoke all on data.balances from pgb_web_user;

drop table if exists data.balances;

-- +goose StatementEnd
