# Useful Queries

## Budget View

### Direct Query

The following query displays a budget view showing each account's budgeted amount, activity, and current balance:

```sql
SELECT 
    a.name AS account_name,
    COALESCE(
        (SELECT SUM(t.amount)
         FROM data.transactions t
         JOIN data.accounts income_acc ON t.debit_account_id = income_acc.id
         WHERE income_acc.name = 'Income'
         AND t.credit_account_id = a.id),
        0
    ) AS budgeted,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        JOIN data.accounts credit_acc ON t.credit_account_id = credit_acc.id
        JOIN data.accounts debit_acc ON t.debit_account_id = debit_acc.id
        WHERE (t.credit_account_id = a.id OR t.debit_account_id = a.id)
          AND (credit_acc.type IN ('asset', 'liability') OR debit_acc.type IN ('asset', 'liability'))),
        0
    ) AS activity,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        WHERE t.credit_account_id = a.id OR t.debit_account_id = a.id),
        0
    ) AS balance
FROM 
    data.accounts a
ORDER BY 
    a.name;
```

### Using a View

Alternatively, you can create a view for easier querying:

```sql
-- Create the view
CREATE OR REPLACE VIEW data.account_balances AS
SELECT 
    a.name AS account_name,
    COALESCE(
        (SELECT SUM(t.amount)
         FROM data.transactions t
         JOIN data.accounts income_acc ON t.debit_account_id = income_acc.id
         WHERE income_acc.name = 'Income'
         AND t.credit_account_id = a.id),
        0
    ) AS budgeted,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        JOIN data.accounts credit_acc ON t.credit_account_id = credit_acc.id
        JOIN data.accounts debit_acc ON t.debit_account_id = debit_acc.id
        WHERE (t.credit_account_id = a.id OR t.debit_account_id = a.id)
          AND (credit_acc.type IN ('asset', 'liability') OR debit_acc.type IN ('asset', 'liability'))),
        0
    ) AS activity,
    COALESCE(
        (SELECT SUM(
            CASE 
                WHEN t.credit_account_id = a.id THEN t.amount 
                WHEN t.debit_account_id = a.id THEN -t.amount 
                ELSE 0 
            END
        ) FROM data.transactions t
        WHERE t.credit_account_id = a.id OR t.debit_account_id = a.id),
        0
    ) AS balance
FROM 
    data.accounts a
ORDER BY 
    a.name;

-- Then query it simply with:
SELECT * FROM data.account_balances;

-- Or filter as needed:
SELECT * FROM data.account_balances WHERE balance > 0;
```

This query calculates:
- **Budgeted**: The amount allocated from Income to each category
- **Activity**: Transactions involving real-world accounts (assets/liabilities)
- **Balance**: The current balance of each account

For budget categories (which are equity accounts):
- A positive balance means you have money available to spend
- A negative balance indicates overspending
- The difference between budgeted and activity shows how much of your budget remains
