-- +goose Up
-- +goose StatementBegin

-- create a function that will be called by the trigger
create or replace function utils.update_account_balance()
    returns trigger as $$
declare
    v_debit_account_previous_balance  bigint;
    v_debit_account_internal_type     text; -- CORRECTED: Was data.account_internal_type
    v_delta_debit                     bigint;

    v_credit_account_previous_balance bigint;
    v_credit_account_internal_type    text; -- CORRECTED: Was data.account_internal_type
    v_delta_credit                    bigint;

    v_ledger_id                       bigint;
begin
    -- ledger ID is already in the transaction
    v_ledger_id := NEW.ledger_id;

    -- Process DEBIT side
    -- Get previous balance and internal type for the DEBIT account
    select balance into v_debit_account_previous_balance
    from data.balances
    where account_id = new.debit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_debit_account_internal_type
    from data.accounts where id = new.debit_account_id;

    if v_debit_account_previous_balance is null then
        v_debit_account_previous_balance := 0;
    end if;

    if v_debit_account_internal_type is null then
        raise exception 'internal_type not found for debit account %', new.debit_account_id;
    end if;

    -- Calculate delta for DEBIT account
    if v_debit_account_internal_type = 'asset_like' then
        v_delta_debit := new.amount; -- debit to asset increases balance
    elsif v_debit_account_internal_type = 'liability_like' then
        v_delta_debit := -new.amount; -- debit to liability/equity decreases balance
    else
        raise exception 'unknown internal_type % for debit account %', v_debit_account_internal_type, new.debit_account_id;
    end if;

    -- Insert new balance for DEBIT account
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.debit_account_id, new.id, v_ledger_id, v_debit_account_previous_balance, v_delta_debit,
            v_debit_account_previous_balance + v_delta_debit, 'transaction_insert');

    -- Process CREDIT side
    -- Get previous balance and internal type for the CREDIT account
    select balance into v_credit_account_previous_balance
    from data.balances
    where account_id = new.credit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_credit_account_internal_type
    from data.accounts where id = new.credit_account_id;

    if v_credit_account_previous_balance is null then
        v_credit_account_previous_balance := 0;
    end if;

    if v_credit_account_internal_type is null then
        raise exception 'internal_type not found for credit account %', new.credit_account_id;
    end if;

    -- Calculate delta for CREDIT account
    if v_credit_account_internal_type = 'asset_like' then
        v_delta_credit := -new.amount; -- credit to asset decreases balance
    elsif v_credit_account_internal_type = 'liability_like' then
        v_delta_credit := new.amount; -- credit to liability/equity increases balance
    else
        raise exception 'unknown internal_type % for credit account %', v_credit_account_internal_type, new.credit_account_id;
    end if;

    -- Insert new balance for CREDIT account
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.credit_account_id, new.id, v_ledger_id, v_credit_account_previous_balance, v_delta_credit,
            v_credit_account_previous_balance + v_delta_credit, 'transaction_insert');

    return NEW;
end;
$$ language plpgsql security definer;

-- function to handle balance updates when a transaction is deleted
create or replace function utils.handle_transaction_delete_balance()
    returns trigger as
$$
declare
    v_old_debit_account_previous_balance  bigint;
    v_old_debit_account_internal_type     text;
    v_delta_reversal_debit                bigint;

    v_old_credit_account_previous_balance bigint;
    v_old_credit_account_internal_type    text;
    v_delta_reversal_credit               bigint;
begin
    -- REVERSAL FOR OLD DEBIT ACCOUNT
    -- get previous balance and internal type for the OLD DEBIT account
    select balance into v_old_debit_account_previous_balance
    from data.balances
    where account_id = old.debit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_old_debit_account_internal_type
    from data.accounts where id = old.debit_account_id;

    if v_old_debit_account_previous_balance is null then
        v_old_debit_account_previous_balance := 0;
    end if;

    if v_old_debit_account_internal_type is null then
        raise exception 'internal_type not found for old debit account %', old.debit_account_id;
    end if;

    -- calculate reversal delta for OLD DEBIT account
    if v_old_debit_account_internal_type = 'asset_like' then
        v_delta_reversal_debit := -old.amount; -- reversing a debit to asset decreases balance
    elsif v_old_debit_account_internal_type = 'liability_like' then
        v_delta_reversal_debit := old.amount;  -- reversing a debit to liability/equity increases balance
    else
        raise exception 'unknown internal_type % for old debit account %', v_old_debit_account_internal_type, old.debit_account_id;
    end if;

    -- insert balance entry for OLD DEBIT account reversal
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.debit_account_id, old.id, old.ledger_id, v_old_debit_account_previous_balance, v_delta_reversal_debit,
            v_old_debit_account_previous_balance + v_delta_reversal_debit, 'transaction_delete');

    -- REVERSAL FOR OLD CREDIT ACCOUNT
    -- get previous balance and internal type for the OLD CREDIT account
    select balance into v_old_credit_account_previous_balance
    from data.balances
    where account_id = old.credit_account_id
    order by created_at desc, id desc limit 1;

    select internal_type into v_old_credit_account_internal_type
    from data.accounts where id = old.credit_account_id;

    if v_old_credit_account_previous_balance is null then
        v_old_credit_account_previous_balance := 0;
    end if;

    if v_old_credit_account_internal_type is null then
        raise exception 'internal_type not found for old credit account %', old.credit_account_id;
    end if;

    -- calculate reversal delta for OLD CREDIT account
    if v_old_credit_account_internal_type = 'asset_like' then
        v_delta_reversal_credit := old.amount;  -- reversing a credit to asset increases balance
    elsif v_old_credit_account_internal_type = 'liability_like' then
        v_delta_reversal_credit := -old.amount; -- reversing a credit to liability/equity decreases balance
    else
        raise exception 'unknown internal_type % for old credit account %', v_old_credit_account_internal_type, old.credit_account_id;
    end if;

    -- insert balance entry for OLD CREDIT account reversal
    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.credit_account_id, old.id, old.ledger_id, v_old_credit_account_previous_balance, v_delta_reversal_credit,
            v_old_credit_account_previous_balance + v_delta_reversal_credit, 'transaction_delete');

    return old; -- for AFTER DELETE, return value is ignored but OLD is conventional
end;
$$ language plpgsql security definer;

-- function to handle balance updates when a transaction is updated
create or replace function utils.handle_transaction_update_balance()
    returns trigger as
$$
declare
    -- variables for OLD transaction reversal
    v_old_debit_account_previous_balance  bigint;
    v_old_debit_account_internal_type     text;
    v_delta_reversal_old_debit            bigint;

    v_old_credit_account_previous_balance bigint;
    v_old_credit_account_internal_type    text;
    v_delta_reversal_old_credit           bigint;

    -- variables for NEW transaction application
    v_new_debit_account_previous_balance  bigint;
    v_new_debit_account_internal_type     text;
    v_delta_application_new_debit         bigint;

    v_new_credit_account_previous_balance bigint;
    v_new_credit_account_internal_type    text;
    v_delta_application_new_credit        bigint;
begin
    -- STEP 1: REVERSE THE EFFECTS OF THE OLD TRANSACTION VALUES

    -- REVERSAL FOR OLD DEBIT ACCOUNT
    select balance into v_old_debit_account_previous_balance
    from data.balances where account_id = old.debit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_old_debit_account_internal_type
    from data.accounts where id = old.debit_account_id;
    if v_old_debit_account_previous_balance is null then v_old_debit_account_previous_balance := 0; end if;
    if v_old_debit_account_internal_type is null then raise exception 'internal_type not found for old debit account %', old.debit_account_id; end if;

    if v_old_debit_account_internal_type = 'asset_like' then v_delta_reversal_old_debit := -old.amount;
    elsif v_old_debit_account_internal_type = 'liability_like' then v_delta_reversal_old_debit := old.amount;
    else raise exception 'unknown internal_type % for old debit account %', v_old_debit_account_internal_type, old.debit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.debit_account_id, old.id, old.ledger_id, v_old_debit_account_previous_balance, v_delta_reversal_old_debit,
            v_old_debit_account_previous_balance + v_delta_reversal_old_debit, 'transaction_update_reversal');

    -- REVERSAL FOR OLD CREDIT ACCOUNT
    select balance into v_old_credit_account_previous_balance
    from data.balances where account_id = old.credit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_old_credit_account_internal_type
    from data.accounts where id = old.credit_account_id;
    if v_old_credit_account_previous_balance is null then v_old_credit_account_previous_balance := 0; end if;
    if v_old_credit_account_internal_type is null then raise exception 'internal_type not found for old credit account %', old.credit_account_id; end if;

    if v_old_credit_account_internal_type = 'asset_like' then v_delta_reversal_old_credit := old.amount;
    elsif v_old_credit_account_internal_type = 'liability_like' then v_delta_reversal_old_credit := -old.amount;
    else raise exception 'unknown internal_type % for old credit account %', v_old_credit_account_internal_type, old.credit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (old.credit_account_id, old.id, old.ledger_id, v_old_credit_account_previous_balance, v_delta_reversal_old_credit,
            v_old_credit_account_previous_balance + v_delta_reversal_old_credit, 'transaction_update_reversal');

    -- STEP 2: APPLY THE EFFECTS OF THE NEW TRANSACTION VALUES

    -- APPLICATION FOR NEW DEBIT ACCOUNT
    -- Previous balance for the NEW debit account is the latest balance *after* any reversal involving this account.
    select balance into v_new_debit_account_previous_balance
    from data.balances where account_id = new.debit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_new_debit_account_internal_type
    from data.accounts where id = new.debit_account_id;
    if v_new_debit_account_previous_balance is null then v_new_debit_account_previous_balance := 0; end if; -- Should not be null if reversal happened correctly
    if v_new_debit_account_internal_type is null then raise exception 'internal_type not found for new debit account %', new.debit_account_id; end if;

    if v_new_debit_account_internal_type = 'asset_like' then v_delta_application_new_debit := new.amount;
    elsif v_new_debit_account_internal_type = 'liability_like' then v_delta_application_new_debit := -new.amount;
    else raise exception 'unknown internal_type % for new debit account %', v_new_debit_account_internal_type, new.debit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.debit_account_id, new.id, new.ledger_id, v_new_debit_account_previous_balance, v_delta_application_new_debit,
            v_new_debit_account_previous_balance + v_delta_application_new_debit, 'transaction_update_application');

    -- APPLICATION FOR NEW CREDIT ACCOUNT
    -- Previous balance for the NEW credit account is the latest balance *after* any reversal involving this account.
    select balance into v_new_credit_account_previous_balance
    from data.balances where account_id = new.credit_account_id
    order by created_at desc, id desc limit 1;
    select internal_type into v_new_credit_account_internal_type
    from data.accounts where id = new.credit_account_id;
    if v_new_credit_account_previous_balance is null then v_new_credit_account_previous_balance := 0; end if; -- Should not be null if reversal happened correctly
    if v_new_credit_account_internal_type is null then raise exception 'internal_type not found for new credit account %', new.credit_account_id; end if;

    if v_new_credit_account_internal_type = 'asset_like' then v_delta_application_new_credit := -new.amount;
    elsif v_new_credit_account_internal_type = 'liability_like' then v_delta_application_new_credit := new.amount;
    else raise exception 'unknown internal_type % for new credit account %', v_new_credit_account_internal_type, new.credit_account_id; end if;

    insert into data.balances (account_id, transaction_id, ledger_id, previous_balance, delta, balance, operation_type)
    values (new.credit_account_id, new.id, new.ledger_id, v_new_credit_account_previous_balance, v_delta_application_new_credit,
            v_new_credit_account_previous_balance + v_delta_application_new_credit, 'transaction_update_application');

    return new;
end;
$$ language plpgsql security definer;

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

-- drop the function to handle transaction updates
drop function if exists utils.handle_transaction_update_balance();

-- drop the function to handle transaction deletes
drop function if exists utils.handle_transaction_delete_balance();

-- drop the function to get budget status
drop function if exists utils.get_budget_status(integer);

-- drop the function to get account balance
drop function if exists utils.get_account_balance(integer, integer);

-- drop the function to get account transactions
drop function if exists utils.get_account_transactions(integer);

-- drop the trigger function
drop function if exists utils.update_account_balance();

-- +goose StatementEnd
