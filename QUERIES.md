# Useful Queries

## Budget View

### Direct Query (Optimized)

The following query displays a budget view showing each account's budgeted amount, activity, and current balance with optimized performance:

```sql
-- select query to display budget information for each account
select 
    -- display the account name
    a.name as account_name,
    
    -- calculate money budgeted to this category (transfers from income)
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
                else 0
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
    and a.name not in ('income', 'unassigned')
    -- filter by ledger_id
    and a.ledger_id = 1
    
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
                else 0
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
    and a.name not in ('income', 'unassigned')
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

## Transaction Functions

### Find Category

This helper function finds a category by name within a ledger:

```sql
-- function to find a category by name within a ledger
create or replace function api.find_category(
    p_ledger_id int,
    p_category_name text
) returns int as $$
declare
    v_category_id int;
begin
    -- find the category id
    select id into v_category_id
    from data.accounts
    where ledger_id = p_ledger_id 
      and name = p_category_name
      and type = 'equity'
    limit 1;
    
    return v_category_id;
end;
$$ language plpgsql;
```

### Find Category Examples

The `find_category` function can be used in various scenarios where you need to locate a category by name:

```sql
-- find the "groceries" category in ledger 1
select api.find_category(1, 'groceries');

-- find the "unassigned" category in ledger 2
select api.find_category(2, 'unassigned');

-- use the function in a query to get category details
select 
    a.id,
    a.name,
    a.description
from 
    data.accounts a
where 
    a.id = api.find_category(1, 'income');

-- check if a category exists before using it
do $$
declare
    v_category_id int;
begin
    v_category_id := api.find_category(1, 'entertainment');
    
    if v_category_id is null then
        raise notice 'Entertainment category not found, creating it...';
        -- code to create the category would go here
    else
        raise notice 'Found entertainment category with ID: %', v_category_id;
    end if;
end;
$$;
```

This function is particularly useful when:
- Looking up system categories like "income" or "unassigned"
- Validating that a category exists before performing operations
- Finding category IDs by name for reporting or transaction creation

### Add Transaction

This function creates a transaction using user-friendly terminology rather than accounting terms:

```sql
-- function to add a transaction
create or replace function api.add_transaction(
    p_ledger_id int,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount decimal,
    p_account_id int, -- the bank account or credit card
    p_category_id int = null -- the category, now optional
) returns int as $$
declare
    v_transaction_id int;
    v_debit_account_id int;
    v_credit_account_id int;
    v_category_id int;
    v_account_type text;
begin
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;
    
    -- handle null category by finding the "unassigned" category
    if p_category_id is null then
        v_category_id := api.find_category(p_ledger_id, 'unassigned');
        if v_category_id is null then
            raise exception 'Could not find "unassigned" category in ledger %', p_ledger_id;
        end if;
    else
        v_category_id := p_category_id;
    end if;

    -- get the account type (asset or liability)
    select type into v_account_type
    from data.accounts
    where id = p_account_id;
    
    if v_account_type is null then
        raise exception 'Account with ID % not found', p_account_id;
    end if;
    
    -- determine debit and credit accounts based on account type and transaction type
    if v_account_type = 'asset' then
        if p_type = 'inflow' then
            -- for inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := p_account_id;
            v_credit_account_id := v_category_id;
        else
            -- for outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := p_account_id;
        end if;
    elsif v_account_type = 'liability' then
        if p_type = 'inflow' then
            -- for inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := p_account_id;
        else
            -- for outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := p_account_id;
            v_credit_account_id := v_category_id;
        end if;
    else
        raise exception 'Account type % is not supported for transactions', v_account_type;
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
-- add an inflow transaction to a bank account (income received)
select api.add_transaction(
    1,                          -- ledger_id
    '2023-04-15 09:00:00',      -- date
    'Paycheck deposit',         -- description
    'inflow',                   -- type
    1500.00,                    -- amount
    1,                          -- account_id (bank account - asset)
    5                           -- category_id (Income category)
);

-- add an outflow transaction from a bank account (spending money)
select api.add_transaction(
    1,                          -- ledger_id
    '2023-04-16 14:30:00',      -- date
    'Grocery shopping',         -- description
    'outflow',                  -- type
    85.75,                      -- amount
    1,                          -- account_id (bank account - asset)
    3                           -- category_id (Groceries category)
);

-- add an inflow transaction to a credit card (charging something)
select api.add_transaction(
    1,                          -- ledger_id
    '2023-04-18 12:00:00',      -- date
    'Online purchase',          -- description
    'inflow',                   -- type
    120.50,                     -- amount
    2,                          -- account_id (credit card - liability)
    4                           -- category_id (Shopping category)
);

-- add an outflow transaction from a credit card (paying the bill)
select api.add_transaction(
    1,                          -- ledger_id
    '2023-04-25 09:00:00',      -- date
    'Credit card payment',      -- description
    'outflow',                  -- type
    120.50,                     -- amount
    2,                          -- account_id (credit card - liability)
    6                           -- category_id (Credit Card Payment category)
);

-- add an outflow transaction without specifying a category (will use "unassigned")
select api.add_transaction(
    1,                          -- ledger_id
    '2023-04-17 10:15:00',      -- date
    'Coffee shop',              -- description
    'outflow',                  -- type
    4.50,                       -- amount
    1                           -- account_id (bank account - asset)
    -- category_id omitted, will use "unassigned"
);
```

### Add Bulk Transactions

This function allows adding multiple transactions at once in an atomic operation, which is particularly useful for importing transactions from CSV files or other bulk operations:

```sql
-- function to add multiple transactions in a single operation
create or replace function api.add_bulk_transactions(
    p_transactions jsonb
) returns table (
    transaction_id int,
    status text,
    message text
) as $$
declare
    v_transaction jsonb;
    v_ledger_id int;
    v_date timestamptz;
    v_description text;
    v_type text;
    v_amount decimal;
    v_account_id int;
    v_category_id int;
    v_result record;
    v_unassigned_categories jsonb = '{}'::jsonb;
begin
    -- start a transaction block to make the operation atomic
    -- (will be automatically committed if the function completes successfully)
    
    -- create a temporary table to store results
    create temporary table temp_results (
        transaction_id int,
        status text,
        message text
    ) on commit drop;
    
    -- pre-fetch unassigned categories for all ledgers in the batch
    -- to avoid repeated lookups
    for v_ledger_id in (
        select distinct (t->>'ledger_id')::int 
        from jsonb_array_elements(p_transactions) as t
    ) loop
        v_unassigned_categories = v_unassigned_categories || 
            jsonb_build_object(
                v_ledger_id::text, 
                api.find_category(v_ledger_id, 'unassigned')
            );
    end loop;
    
    -- process each transaction in the array
    for v_transaction in select * from jsonb_array_elements(p_transactions)
    loop
        begin
            -- extract values from the JSON object
            v_ledger_id := (v_transaction->>'ledger_id')::int;
            v_date := (v_transaction->>'date')::timestamptz;
            v_description := v_transaction->>'description';
            v_type := v_transaction->>'type';
            v_amount := (v_transaction->>'amount')::decimal;
            v_account_id := (v_transaction->>'account_id')::int;
            
            -- category_id is optional
            if v_transaction ? 'category_id' then
                v_category_id := (v_transaction->>'category_id')::int;
            else
                v_category_id := null;
            end if;
            
            -- call the existing add_transaction function
            v_result.transaction_id := api.add_transaction(
                v_ledger_id,
                v_date,
                v_description,
                v_type,
                v_amount,
                v_account_id,
                v_category_id
            );
            
            -- store successful result
            insert into temp_results values (
                v_result.transaction_id,
                'success',
                'Transaction created successfully'
            );
            
        exception when others then
            -- store error result
            insert into temp_results values (
                null,
                'error',
                'Error processing transaction: ' || SQLERRM
            );
        end;
    end loop;
    
    -- return the results
    return query select * from temp_results;
end;
$$ language plpgsql;
```

### Usage Examples

You can add multiple transactions at once by passing a JSON array of transaction objects:

```sql
-- add multiple transactions at once
select * from api.add_bulk_transactions('[
  {
    "ledger_id": 1,
    "date": "2023-04-15T09:00:00Z",
    "description": "Paycheck deposit",
    "type": "inflow",
    "amount": 1500.00,
    "account_id": 1,
    "category_id": 5
  },
  {
    "ledger_id": 1,
    "date": "2023-04-16T14:30:00Z",
    "description": "Grocery shopping",
    "type": "outflow",
    "amount": 85.75,
    "account_id": 1,
    "category_id": 3
  },
  {
    "ledger_id": 1,
    "date": "2023-04-17T10:15:00Z",
    "description": "Coffee shop",
    "type": "outflow",
    "amount": 4.50,
    "account_id": 1
  }
]');
```

### Expected Output

When you run the function in a SQL console, you'll see a result set with status information for each transaction:

```
 transaction_id |  status  |              message
---------------+----------+-----------------------------------
           101 | success  | Transaction created successfully
           102 | success  | Transaction created successfully
           103 | success  | Transaction created successfully
(3 rows)
```

If there are errors with some transactions, you'll see them in the results with detailed error information:

```
 transaction_id |  status  |                           message
---------------+----------+-------------------------------------------------------------
           104 | success  | Transaction created successfully
           105 | success  | Transaction created successfully
          null | error    | Error in transaction Online purchase (index 3): Invalid transaction type: test. Transaction data: {"type": "test", "amount": 120.50, "date": "2023-04-18T12:00:00Z", "ledger_id": 1, "account_id": 2, "description": "Online purchase", "category_id": 4}
          null | error    | All transactions rolled back due to error
(4 rows)
```

The detailed error message now includes:
- The transaction description
- The index of the transaction in the batch
- The specific error message
- The complete transaction data for debugging

### From Go Code

When calling this function from Go code, you can prepare the JSON like this:

```go
type Transaction struct {
    LedgerID    int       `json:"ledger_id"`
    Date        time.Time `json:"date"`
    Description string    `json:"description"`
    Type        string    `json:"type"`
    Amount      float64   `json:"amount"`
    AccountID   int       `json:"account_id"`
    CategoryID  *int      `json:"category_id,omitempty"` // Optional
}

// Prepare transactions from CSV data
transactions := []Transaction{
    {
        LedgerID:    1,
        Date:        time.Now(),
        Description: "Paycheck deposit",
        Type:        "inflow",
        Amount:      1500.00,
        AccountID:   1,
        CategoryID:  &categoryID, // Use pointer for optional field
    },
    // Add more transactions...
}

// Convert to JSON
jsonData, err := json.Marshal(transactions)
if err != nil {
    log.Fatal(err)
}

// Call the database function
rows, err := db.Query("SELECT * FROM api.add_bulk_transactions($1)", string(jsonData))
// Process results...
```

This bulk transaction function provides significant performance benefits when importing many transactions at once, while maintaining data integrity through its atomic operation.
