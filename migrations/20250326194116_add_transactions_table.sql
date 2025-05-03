-- +goose Up
-- +goose StatementBegin

create table data.transactions
(
    id                bigint generated always as identity primary key,
    uuid              text        not null default utils.nanoid(8),

    created_at        timestamptz not null default current_timestamp,
    updated_at        timestamptz not null default current_timestamp,

    amount            bigint      not null default 0,
    date              date,
    description       text,
    metadata          jsonb,
    status            text        not null default 'posted',

    credit_account_id bigint      not null references data.accounts (id),
    debit_account_id  bigint      not null references data.accounts (id),

    user_data         text        not null,

    -- fks
    ledger_id         bigint      not null references data.ledgers (id) on delete cascade,

    constraint transactions_uuid_unique unique (uuid),
    constraint transactions_amount_positive check (amount >= 0),
    constraint transactions_different_accounts check (credit_account_id != debit_account_id),
    constraint transactions_description_length_check check (char_length(description) < 255),
    constraint transactions_user_data_length_check check (char_length(user_data) < 255),
    constraint transactions_status_check check (status in ('pending', 'posted'))
);

create trigger transactions_updated_at_tg
    before update
    on data.transactions
    for each row
execute procedure utils.set_updated_at_fn();

-- allow authenticated user to access the transactions table.
grant all on data.transactions to pgb_web_user;
grant usage, select on sequence data.transactions_id_seq to pgb_web_user;

-- enable RLS
alter table data.transactions
    enable row level security;

create policy transactions_policy on data.transactions
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists transactions_policy on data.transactions;

revoke all on data.transactions from pgb_web_user;

drop trigger if exists transactions_updated_at_tg on data.transactions;

drop table data.transactions;

-- +goose StatementEnd
