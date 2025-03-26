-- +goose Up
-- +goose StatementBegin
create table data.transactions
(
    id                bigint generated always as identity primary key,

    created_at        timestamptz not null default current_timestamp,
    updated_at        timestamptz not null default current_timestamp,

    amount            bigint      not null default 0,
    date              date,
    description       text,
    metadata          jsonb,
    status            text        not null default 'posted',

    credit_account_id bigint      not null references data.accounts (id),
    debit_account_id  bigint      not null references data.accounts (id),

    ledger_id         bigint      not null references data.ledgers (id),

    constraint transactions_amount_positive check (amount >= 0),
    constraint transactions_different_accounts check (credit_account_id != debit_account_id),
    constraint transactions_description_length_check check (char_length(description) < 255),
    constraint transactions_status_check check (status in ('pending', 'posted'))
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop table data.transactions;
-- +goose StatementEnd
