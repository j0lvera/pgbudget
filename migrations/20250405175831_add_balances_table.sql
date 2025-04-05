-- +goose Up
-- +goose StatementBegin
create table if not exists data.balances
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

    constraint balances_operation_type_check check (
        operation_type in ('credit', 'debit')
        ),
    constraint balances_delta_valid_check check (
        (operation_type = 'debit' and delta > 0) or
        (operation_type = 'credit' and delta < 0)
        )
);

-- Index for fetching latest balance quickly
create index if not exists balances_account_latest_idx
    on data.balances (account_id, created_at desc);

-- Create a function that will be called by the trigger
create or replace function data.update_account_balance()
returns trigger as $$
declare
    v_previous_balance bigint;
    v_new_balance bigint;
    v_operation_type text;
    v_delta bigint;
    v_ledger_id bigint;
begin
    -- Get the ledger_id from the account
    select ledger_id into v_ledger_id
    from data.accounts
    where id = NEW.account_id;

    -- Get the previous balance (or 0 if no previous balance exists)
    select coalesce(balance, 0) into v_previous_balance
    from data.balances
    where account_id = NEW.account_id
    order by created_at desc
    limit 1;

    -- Determine operation type and delta based on debit or credit
    if NEW.is_debit then
        v_operation_type := 'debit';
        v_delta := NEW.amount;
        v_new_balance := v_previous_balance + NEW.amount;
    else
        v_operation_type := 'credit';
        v_delta := -NEW.amount; -- Store as negative for credits
        v_new_balance := v_previous_balance - NEW.amount;
    end if;

    -- Insert the new balance record
    insert into data.balances (
        previous_balance,
        balance,
        delta,
        operation_type,
        account_id,
        ledger_id,
        transaction_id
    ) values (
        v_previous_balance,
        v_new_balance,
        v_delta,
        v_operation_type,
        NEW.account_id,
        v_ledger_id,
        NEW.transaction_id
    );

    return NEW;
end;
$$ language plpgsql;

-- Create the trigger on transaction_entries
create trigger update_account_balance_trigger
after insert on data.transaction_entries
for each row
execute function data.update_account_balance();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop trigger if exists update_account_balance_trigger on data.transaction_entries;
drop function if exists data.update_account_balance();
drop table if exists data.balances;
drop index if exists balances_account_latest_idx;
-- +goose StatementEnd
