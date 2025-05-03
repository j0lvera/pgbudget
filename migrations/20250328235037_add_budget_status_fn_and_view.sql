-- +goose Up
-- +goose StatementBegin

-- create a function in utils schema to get budget status for a specific ledger by internal id
create or replace function utils.get_budget_status(p_ledger_id int)
returns table (
    id bigint,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
) as $$
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

-- create a wrapper function in api schema that uses the utils function with uuid
create or replace function api.get_budget_status(p_ledger_uuid uuid)
returns table (
    id bigint,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
) as $$
declare
    v_ledger_id int;
begin
    -- find the ledger id from the uuid
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid;
    
    if v_ledger_id is null then
        raise exception 'ledger with uuid % not found', p_ledger_uuid;
    end if;

    -- call the utils function with the internal id
    return query
    select * from utils.get_budget_status(v_ledger_id);
end;
$$ language plpgsql;

-- create a view that uses the accounts table for security inheritance
create or replace view data.budget_status as
select 
    bs.id,
    bs.account_name,
    bs.budgeted,
    bs.activity,
    bs.balance
from data.accounts a
cross join lateral (
    select * from utils.get_budget_status(a.ledger_id)
    where id = a.id
) bs;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the view and functions when rolling back
drop view if exists data.budget_status;
drop function if exists api.get_budget_status(uuid);
drop function if exists utils.get_budget_status(int);

-- +goose StatementEnd
