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

-- create trigger for updated_at
create trigger balances_updated_at_tg
    before update
    on data.balances
    for each row
execute procedure utils.set_updated_at_fn();

-- grant permissions to pgb_web_user
grant all on data.balances to pgb_web_user;
grant usage, select on sequence data.balances_id_seq to pgb_web_user;

-- enable row level security
alter table data.balances
    enable row level security;

create policy balances_policy on data.balances
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- create a function that will be called by the trigger
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
    -- ledger ID is already in the transaction
    v_ledger_id := NEW.ledger_id;

    -- process both debit and credit sides of the transaction
    -- first, handle the debit account
    -- get the account's internal type
    select internal_type into v_internal_type
    from data.accounts
    where id = NEW.debit_account_id;

    -- check if there's a previous balance record
    select exists(
        select 1 from data.balances
        where account_id = NEW.debit_account_id
    ) into v_has_previous;

    -- get the previous balance (or 0 if no previous balance exists)
    if v_has_previous then
        select balance into v_previous_balance
        from data.balances
        where account_id = NEW.debit_account_id
        order by created_at desc
        limit 1;
    else
        v_previous_balance := 0;
    end if;

    -- for debit account, it's always a debit operation
    v_operation_type := 'debit';
    v_delta := NEW.amount;
    
    -- calculate new balance based on account type
    if v_internal_type = 'asset_like' then
        -- for asset-like accounts, debits increase the balance
        v_new_balance := v_previous_balance + NEW.amount;
    else
        -- for liability-like accounts, debits decrease the balance
        v_new_balance := v_previous_balance - NEW.amount;
    end if;

    -- insert the new balance record for debit account
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

    -- now, handle the credit account
    -- get the account's internal type
    select internal_type into v_internal_type
    from data.accounts
    where id = NEW.credit_account_id;

    -- check if there's a previous balance record
    select exists(
        select 1 from data.balances
        where account_id = NEW.credit_account_id
    ) into v_has_previous;

    -- get the previous balance (or 0 if no previous balance exists)
    if v_has_previous then
        select balance into v_previous_balance
        from data.balances
        where account_id = NEW.credit_account_id
        order by created_at desc
        limit 1;
    else
        v_previous_balance := 0;
    end if;

    -- for credit account, it's always a credit operation
    v_operation_type := 'credit';
    v_delta := -NEW.amount; -- Store as negative for credits
    
    -- calculate new balance based on account type
    if v_internal_type = 'asset_like' then
        -- for asset-like accounts, credits decrease the balance
        v_new_balance := v_previous_balance - NEW.amount;
    else
        -- for liability-like accounts, credits increase the balance
        v_new_balance := v_previous_balance + NEW.amount;
    end if;

    -- insert the new balance record for credit account
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

-- create the trigger on transactions table
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
                      balance bigint  -- new column for transaction balance
                  ) as $$
declare
    v_internal_type text;
begin
    -- cet the account's internal type to determine how to display transactions
    select internal_type into v_internal_type
    from data.accounts
    where id = p_account_id;

    return query
          with account_transactions as (
              -- for asset-like accounts:
              -- - debits (money coming in) should be shown as "inflow"
              -- - credits (money going out) should be shown as "outflow"
              -- for liability-like accounts, it's the opposite:
              -- - debits (paying down debt) should be shown as "outflow"
              -- - credits (increasing debt) should be shown as "inflow"
              
              -- transactions where this account is debited
              select
                  t.date,
                  a.name as category,
                  t.description,
                  case when v_internal_type = 'asset_like' then 'inflow'
                       else 'outflow' end as type,
                  t.amount, -- always positive
                  t.id as transaction_id,
                  t.created_at
                from data.transactions t
                     join data.accounts a on t.credit_account_id = a.id
               where t.debit_account_id = p_account_id

               union all

              -- transactions where this account is credited
              select
                  t.date,
                  a.name as category,
                  t.description,
                  case when v_internal_type = 'asset_like' then 'outflow'
                       else 'inflow' end as type,
                  t.amount, -- always positive
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
            b.balance  -- get the balance from the balances table
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

drop policy if exists balances_policy on data.balances;

revoke all on data.balances from pgb_web_user;

drop trigger if exists balances_updated_at_tg on data.balances;

drop table if exists data.balances;

drop index if exists balances_account_latest_idx;

drop function if exists api.get_account_transactions(int);

-- +goose StatementEnd
