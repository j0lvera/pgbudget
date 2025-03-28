# Useful Queries

## Budget View

### Direct Query (Optimized)

The following query displays a budget view showing each account's budgeted amount, activity, and current balance with optimized performance:

```sql
-- Select query to display budget information for each account
SELECT 
    -- Display the account name
    a.name AS account_name,
    -- Calculate money budgeted to this category (transfers from Income)
    COALESCE(SUM(CASE 
        WHEN t.debit_account_id = income.id AND t.credit_account_id = a.id 
        THEN t.amount 
        ELSE 0 
    END), 0) AS budgeted,
    -- Calculate spending activity (transactions with real-world accounts)
    COALESCE(SUM(CASE 
        WHEN (t.credit_account_id = a.id OR t.debit_account_id = a.id)
        AND (credit_acc.type IN ('asset', 'liability') OR debit_acc.type IN ('asset', 'liability'))
        THEN 
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
            END
        ELSE 0 
    END), 0) AS activity,
    -- Calculate current balance (all transactions affecting this account)
    COALESCE(SUM(CASE 
        WHEN t.credit_account_id = a.id THEN t.amount 
        WHEN t.debit_account_id = a.id THEN -t.amount 
        ELSE 0 
    END), 0) AS balance
FROM 
    -- Start with budget category accounts only
    data.accounts a
WHERE
    -- Filter to only include budget categories (equity accounts that aren't system accounts)
    a.type = 'equity'
    AND a.name NOT IN ('Income', 'Unallocated')
-- Include all transactions affecting each account
LEFT JOIN data.transactions t ON 
    t.credit_account_id = a.id OR t.debit_account_id = a.id
-- Find the Income account in the same ledger
LEFT JOIN data.accounts income ON 
    income.name = 'Income' AND income.ledger_id = a.ledger_id
-- Join to get credit account type information
LEFT JOIN data.accounts credit_acc ON 
    t.credit_account_id = credit_acc.id
-- Join to get debit account type information
LEFT JOIN data.accounts debit_acc ON 
    t.debit_account_id = debit_acc.id
-- Group results by account
GROUP BY 
    a.id, a.name
-- Sort alphabetically by account name
ORDER BY 
    a.name;
```

### Using a View (Optimized)

For better performance, create a view using the optimized query:

```sql
-- Create the view
CREATE OR REPLACE VIEW data.account_balances AS
SELECT 
    a.ledger_id,
    a.name AS account_name,
    COALESCE(SUM(CASE 
        WHEN t.debit_account_id = income.id AND t.credit_account_id = a.id 
        THEN t.amount 
        ELSE 0 
    END), 0) AS budgeted,
    COALESCE(SUM(CASE 
        WHEN (t.credit_account_id = a.id OR t.debit_account_id = a.id)
        AND (credit_acc.type IN ('asset', 'liability') OR debit_acc.type IN ('asset', 'liability'))
        THEN 
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
            END
        ELSE 0 
    END), 0) AS activity,
    COALESCE(SUM(CASE 
        WHEN t.credit_account_id = a.id THEN t.amount 
        WHEN t.debit_account_id = a.id THEN -t.amount 
        ELSE 0 
    END), 0) AS balance
FROM 
    data.accounts a
WHERE
    -- Filter to only include budget categories (equity accounts that aren't system accounts)
    a.type = 'equity'
    AND a.name NOT IN ('Income', 'Unallocated')
LEFT JOIN data.transactions t ON 
    t.credit_account_id = a.id OR t.debit_account_id = a.id
LEFT JOIN data.accounts income ON 
    income.name = 'Income' AND income.ledger_id = a.ledger_id
LEFT JOIN data.accounts credit_acc ON 
    t.credit_account_id = credit_acc.id
LEFT JOIN data.accounts debit_acc ON 
    t.debit_account_id = debit_acc.id
GROUP BY 
    a.id, a.name, a.ledger_id
ORDER BY 
    a.name;

-- Then query it simply with:
SELECT * FROM data.account_balances;

-- Or filter by ledger:
SELECT * FROM data.account_balances WHERE ledger_id = 1;

-- Or filter by balance:
SELECT * FROM data.account_balances WHERE balance > 0;
```

### Recommended Indexes

To support these queries efficiently, add these indexes:

```sql
-- Index for account lookups by name (for finding 'Income' accounts)
CREATE INDEX idx_accounts_name ON data.accounts(name, ledger_id);

-- Indexes for transaction lookups
CREATE INDEX idx_transactions_credit_account ON data.transactions(credit_account_id);
CREATE INDEX idx_transactions_debit_account ON data.transactions(debit_account_id);

-- Composite index for account type lookups
CREATE INDEX idx_accounts_type ON data.accounts(id, type);

-- Composite index for budget category filtering
CREATE INDEX idx_accounts_budget_filter ON data.accounts(ledger_id, type, name);
```

### For Large Datasets: Materialized View

For large datasets, consider using a materialized view that can be refreshed periodically:

```sql
CREATE MATERIALIZED VIEW data.account_balances_mat AS
-- Same query as the optimized view above
;

-- Then refresh when needed:
REFRESH MATERIALIZED VIEW data.account_balances_mat;
```

This query calculates:
- **Budgeted**: The amount allocated from Income to each category
- **Activity**: Transactions involving real-world accounts (assets/liabilities)
- **Balance**: The current balance of each account

For budget categories (which are equity accounts):
- A positive balance means you have money available to spend
- A negative balance indicates overspending
- The difference between budgeted and activity shows how much of your budget remains
