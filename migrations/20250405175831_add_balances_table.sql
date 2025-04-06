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
    v_internal_type text;
begin
    -- Ledger ID is already in the transaction
    v_ledger_id := NEW.ledger_id;

    -- Process both debit and credit sides of the transaction
    -- First, handle the debit account
    -- Get the account's internal type
    select internal_type into v_internal_type
    from data.accounts
    where id = NEW.debit_account_id;

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
    
    -- Calculate new balance based on account type
    if v_internal_type = 'asset_like' then
        -- For asset-like accounts, debits increase the balance
        v_new_balance := v_previous_balance + NEW.amount;
    else
        -- For liability-like accounts, debits decrease the balance
        v_new_balance := v_previous_balance - NEW.amount;
    end if;

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
    -- Get the account's internal type
    select internal_type into v_internal_type
    from data.accounts
    where id = NEW.credit_account_id;

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
    
    -- Calculate new balance based on account type
    if v_internal_type = 'asset_like' then
        -- For asset-like accounts, credits decrease the balance
        v_new_balance := v_previous_balance - NEW.amount;
    else
        -- For liability-like accounts, credits increase the balance
        v_new_balance := v_previous_balance + NEW.amount;
    end if;

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

create or replace function api.get_account_transactions(p_account_id int)
    returns table (
                      date date,
                      category text,
                      description text,
                      type text,
                      amount bigint,
                      balance bigint  -- New column for transaction balance
                  ) as $$
begin
    return query
          with account_transactions as (
              -- Transactions where this account is debited (money going out for asset accounts)
              select
                  t.date,
                  a.name as category,
                  t.description,
                  'outflow' as type,
                  -t.amount as amount,
                  t.id as transaction_id,
                  t.created_at
                from data.transactions t
                     join data.accounts a on t.credit_account_id = a.id
               where t.debit_account_id = p_account_id

               union all

              -- Transactions where this account is credited (money coming in for asset accounts)
              select
                  t.date,
                  a.name as category,
                  t.description,
                  'inflow' as type,
                  t.amount as amount,
                  t.id as transaction_id,
                  t.created_at
                from data.transactions t
                     join data.accounts a on t.debit_account_id = a.id
               where t.credit_account_id = p_account_id
          )
        select
            at.date,
            at.category,
            at.description,
            at.type,
            at.amount,
            b.balance  -- Get the balance from the balances table
          from account_transactions at
               left join data.balances b on
              b.transaction_id = at.transaction_id and
              b.account_id = p_account_id
         order by at.date desc, at.created_at desc;
end;
$$ language plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
drop trigger if exists update_account_balance_trigger on data.transactions;
drop function if exists data.update_account_balance();
drop table if exists data.balances;
drop index if exists balances_account_latest_idx;
drop function if exists api.get_account_transactions(int);
-- +goose StatementEnd
