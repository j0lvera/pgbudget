-- +goose Up
-- +goose StatementBegin

-- create a function to get budget status for a specific ledger
create or replace function api.get_budget_status(p_ledger_id int)
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

-- create a view that uses the function with a default ledger ID
-- according to conventions, data shape definitions should go in the data schema
create or replace view data.budget_status as
select * from api.get_budget_status(1); -- default to ledger_id 1

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- drop the view and function when rolling back
drop view if exists data.budget_status;
drop function if exists api.get_budget_status(int);

-- +goose StatementEnd
