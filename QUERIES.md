# Useful Queries

## Budget View

### Direct Query (Optimized)

The following query displays a budget view showing each account's budgeted amount, activity, and current balance with optimized performance:

```sql
-- select query to display budget information for each account
select 
    -- display the account name
    a.name as account_name,
    
    -- calculate money budgeted to this category (transfers from Income)
    coalesce(sum(case 
        when t.debit_account_id = income.id and t.credit_account_id = a.id 
        then t.amount 
        else 0 
    end), 0) as budgeted,
    
    -- calculate spending activity (transactions with real-world accounts)
    coalesce(sum(case 
        when (t.credit_account_id = a.id or t.debit_account_id = a.id)
        and (credit_acc.type in ('asset', 'liability') or debit_acc.type in ('asset', 'liability'))
        then 
            case 
                when t.credit_account_id = a.id then t.amount 
                when t.debit_account_id = a.id then -t.amount 
            end
        else 0 
    end), 0) as activity,
    
    -- calculate current balance (all transactions affecting this account)
    coalesce(sum(case 
        when t.credit_account_id = a.id then t.amount 
        when t.debit_account_id = a.id then -t.amount 
        else 0 
    end), 0) as balance
from 
    -- start with budget category accounts only
    data.accounts a
where
    -- filter to only include budget categories (equity accounts that aren't system accounts)
    a.type = 'equity'
    and a.name not in ('income', 'unallocated')
    
-- include all transactions affecting each account
left join data.transactions t on 
    t.credit_account_id = a.id or t.debit_account_id = a.id
    
-- find the Income account in the same ledger
left join data.accounts income on 
    income.name = 'income' and income.ledger_id = a.ledger_id
    
-- join to get credit account type information
left join data.accounts credit_acc on 
    t.credit_account_id = credit_acc.id
    
-- join to get debit account type information
left join data.accounts debit_acc on 
    t.debit_account_id = debit_acc.id
    
-- group results by account
group by 
    a.id, a.name
    
-- sort alphabetically by account name
order by 
    a.name;
```

### Using a View (Optimized)

For better performance, create a view using the optimized query:

```sql
-- create the view
create or replace view data.account_balances as
select 
    a.ledger_id,
    a.name as account_name,
    coalesce(sum(case 
        when t.debit_account_id = income.id and t.credit_account_id = a.id 
        then t.amount 
        else 0 
    end), 0) as budgeted,
    coalesce(sum(case 
        when (t.credit_account_id = a.id or t.debit_account_id = a.id)
        and (credit_acc.type in ('asset', 'liability') or debit_acc.type in ('asset', 'liability'))
        then 
            case 
                when t.credit_account_id = a.id then t.amount 
                when t.debit_account_id = a.id then -t.amount 
            end
        else 0 
    end), 0) as activity,
    coalesce(sum(case 
        when t.credit_account_id = a.id then t.amount 
        when t.debit_account_id = a.id then -t.amount 
        else 0 
    end), 0) as balance
from 
    data.accounts a
where
    -- filter to only include budget categories (equity accounts that aren't system accounts)
    a.type = 'equity'
    and a.name not in ('income', 'unallocated')
left join data.transactions t on 
    t.credit_account_id = a.id or t.debit_account_id = a.id
left join data.accounts income on 
    income.name = 'income' and income.ledger_id = a.ledger_id
left join data.accounts credit_acc on 
    t.credit_account_id = credit_acc.id
left join data.accounts debit_acc on 
    t.debit_account_id = debit_acc.id
group by 
    a.id, a.name, a.ledger_id
order by 
    a.name;

-- then query it simply with:
select * from data.account_balances;

-- or filter by ledger:
select * from data.account_balances where ledger_id = 1;

-- or filter by balance:
select * from data.account_balances where balance > 0;
```

### Recommended Indexes

To support these queries efficiently, add these indexes:

```sql
-- index for account lookups by name (for finding 'income' accounts)
create index idx_accounts_name on data.accounts(name, ledger_id);

-- indexes for transaction lookups
create index idx_transactions_credit_account on data.transactions(credit_account_id);
create index idx_transactions_debit_account on data.transactions(debit_account_id);

-- composite index for account type lookups
create index idx_accounts_type on data.accounts(id, type);

-- composite index for budget category filtering
create index idx_accounts_budget_filter on data.accounts(ledger_id, type, name);
```

### For Large Datasets: Materialized View

For large datasets, consider using a materialized view that can be refreshed periodically:

```sql
-- create materialized view for better performance
create materialized view data.account_balances_mat as
-- same query as the optimized view above
;

-- then refresh when needed:
-- refresh materialized view using api schema function
create or replace function api.refresh_account_balances()
returns void as $$
begin
    refresh materialized view data.account_balances_mat;
end;
$$ language plpgsql;

-- call the function to refresh:
select api.refresh_account_balances();
```

This query calculates:
- **Budgeted**: The amount allocated from income to each category
- **Activity**: Transactions involving real-world accounts (assets/liabilities)
- **Balance**: The current balance of each account

For budget categories (which are equity accounts):
- A positive balance means you have money available to spend
- A negative balance indicates overspending
- The difference between budgeted and activity shows how much of your budget remains

## Budget Transaction Functions

### Add Budget Transaction

This function creates a transaction using budgeting terminology rather than accounting terms:

```sql
-- function to add a budget transaction
create or replace function api.add_budget_transaction(
    p_ledger_id int,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount decimal,
    p_account_id int, -- the bank account or credit card
    p_category_id int -- the budget category
) returns int as $$
declare
    v_transaction_id int;
    v_debit_account_id int;
    v_credit_account_id int;
begin
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    -- determine debit and credit accounts based on transaction type
    if p_type = 'inflow' then
        -- for inflow: debit the account (asset increases), credit the category (equity increases)
        v_debit_account_id := p_account_id;
        v_credit_account_id := p_category_id;
    else
        -- for outflow: debit the category (equity decreases), credit the account (asset decreases)
        v_debit_account_id := p_category_id;
        v_credit_account_id := p_account_id;
    end if;

    -- insert the transaction and return the new id
    insert into data.transactions (
        ledger_id,
        date,
        description,
        debit_account_id,
        credit_account_id,
        amount
    ) values (
        p_ledger_id,
        p_date,
        p_description,
        v_debit_account_id,
        v_credit_account_id,
        p_amount
    ) returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql;
```

### Usage Examples

```sql
-- add an inflow transaction (income received)
select api.add_budget_transaction(
    1,                          -- ledger_id
    '2023-04-15 09:00:00',      -- date
    'Paycheck deposit',         -- description
    'inflow',                   -- type
    1500.00,                    -- amount
    1,                          -- account_id (bank account)
    5                           -- category_id (Income category)
);

-- add an outflow transaction (spending money)
select api.add_budget_transaction(
    1,                          -- ledger_id
    '2023-04-16 14:30:00',      -- date
    'Grocery shopping',         -- description
    'outflow',                  -- type
    85.75,                      -- amount
    1,                          -- account_id (bank account)
    3                           -- category_id (Groceries category)
);
```
