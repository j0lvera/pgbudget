-- +goose Up
-- +goose StatementBegin

-- create a function that will be called by the trigger
create or replace function utils.update_account_balance()
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

create or replace function utils.get_account_transactions(p_account_id int)
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

create or replace function utils.get_account_balance(
    p_ledger_id integer,
    p_account_id integer
) returns numeric as $$
declare
    v_internal_type text;
    v_balance numeric;
begin
    -- get the internal type of the account (asset_like or liability_like)
    select internal_type into v_internal_type
      from data.accounts
     where id = p_account_id and ledger_id = p_ledger_id;

    if v_internal_type is null then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;

    -- calculate balance based on internal type
    -- for asset-like accounts: debits increase (positive), credits decrease (negative)
    -- for liability-like accounts: credits increase (positive), debits decrease (negative)
    if v_internal_type = 'asset_like' then
        select coalesce(sum(
                                case
                                    when debit_account_id = p_account_id then amount
                                    when credit_account_id = p_account_id then -amount
                                    else 0
                                    end
                        ), 0) into v_balance
          from data.transactions
         where ledger_id = p_ledger_id
           and (debit_account_id = p_account_id or credit_account_id = p_account_id);
    else -- liability_like
        select coalesce(sum(
                                case
                                    when credit_account_id = p_account_id then amount
                                    when debit_account_id = p_account_id then -amount
                                    else 0
                                    end
                        ), 0) into v_balance
          from data.transactions
         where ledger_id = p_ledger_id
           and (debit_account_id = p_account_id or credit_account_id = p_account_id);
    end if;

    return v_balance;
end;
$$ language plpgsql;

-- create a function to get budget status for a specific ledger
create or replace function utils.get_budget_status(p_ledger_id int)
    returns table
            (
                id           bigint,
                account_name text,
                budgeted     decimal,
                activity     decimal,
                balance      decimal
            )
as
$$
begin
    -- return budget status for all categories in the specified ledger
    return query
        select a.id,
               a.name as account_name,
               -- budgeted amount
               coalesce(
                       (select sum(t.amount)
                          from data.transactions t
                               join data.accounts income_acc on t.debit_account_id = income_acc.id
                         where income_acc.name = 'Income'
                           and t.credit_account_id = a.id),
                       0
               )      as budgeted,
               -- activity
               coalesce(
                       (select sum(
                                       case
                                           when t.credit_account_id = a.id then t.amount
                                           when t.debit_account_id = a.id then -t.amount
                                           else 0
                                           end
                               )
                          from data.transactions t
                               join data.accounts credit_acc on t.credit_account_id = credit_acc.id
                               join data.accounts debit_acc on t.debit_account_id = debit_acc.id
                         where (t.credit_account_id = a.id or t.debit_account_id = a.id)
                           and (credit_acc.type in ('asset', 'liability') or debit_acc.type in ('asset', 'liability'))),
                       0
               )      as activity,
               -- balance or remaining
               coalesce(
                       (select sum(
                                       case
                                           when t.credit_account_id = a.id then t.amount
                                           when t.debit_account_id = a.id then -t.amount
                                           else 0
                                           end
                               )
                          from data.transactions t
                         where t.credit_account_id = a.id
                            or t.debit_account_id = a.id),
                       0
               )      as balance
          from data.accounts a
         where a.ledger_id = p_ledger_id
           and a.type = 'equity'
           and a.name not in ('Income', 'Off-budget', 'Unassigned')
         order by a.name;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the function to get budget status
drop function if exists utils.get_budget_status(integer);

-- drop the function to get account balance
drop function if exists utils.get_account_balance(integer, integer);

-- drop the function to get account transactions
drop function if exists utils.get_account_transactions(integer);

-- drop the trigger function
drop function if exists utils.update_account_balance();

-- +goose StatementEnd
