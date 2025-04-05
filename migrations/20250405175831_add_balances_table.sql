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
    v_has_previous boolean;
begin
    -- Ledger ID is already in the transaction
    v_ledger_id := NEW.ledger_id;

    -- Process both debit and credit sides of the transaction
    -- First, handle the debit account
    -- Check if there's a previous balance record
    select exists(
        select 1 from data.balances
        where account_id = NEW.debit_account_id
    ) into v_has_previous;

    -- Get the previous balance (or 0 if no previous balance exists)
    if v_has_previous then
        select balance into v_previous_balance
        from data.balances
        where account_id = NEW.debit_account_id
        order by created_at desc
        limit 1;
    else
        v_previous_balance := 0;
    end if;

    -- For debit account, it's always a debit operation
    v_operation_type := 'debit';
    v_delta := NEW.amount;
    v_new_balance := v_previous_balance + NEW.amount;

    -- Insert the new balance record for debit account
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
        NEW.debit_account_id,
        v_ledger_id,
        NEW.id
    );

    -- Now, handle the credit account
    -- Check if there's a previous balance record
    select exists(
        select 1 from data.balances
        where account_id = NEW.credit_account_id
    ) into v_has_previous;

    -- Get the previous balance (or 0 if no previous balance exists)
    if v_has_previous then
        select balance into v_previous_balance
        from data.balances
        where account_id = NEW.credit_account_id
        order by created_at desc
        limit 1;
    else
        v_previous_balance := 0;
    end if;

    -- For credit account, it's always a credit operation
    v_operation_type := 'credit';
    v_delta := -NEW.amount; -- Store as negative for credits
    v_new_balance := v_previous_balance - NEW.amount;

    -- Insert the new balance record for credit account
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
        NEW.credit_account_id,
        v_ledger_id,
        NEW.id
    );

    return NEW;
end;
$$ language plpgsql;

-- Create the trigger on transactions table
create trigger update_account_balance_trigger
after insert on data.transactions
for each row
execute function data.update_account_balance();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop trigger if exists update_account_balance_trigger on data.transactions;
drop function if exists data.update_account_balance();
drop table if exists data.balances;
drop index if exists balances_account_latest_idx;
-- +goose StatementEnd
