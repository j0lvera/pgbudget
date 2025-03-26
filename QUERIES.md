# Useful Queries

## Budget View

The following query displays a budget view showing each account and its current balance:

```sql
SELECT 
    a.name AS account_name,
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

This query calculates the balance for each account by:
- Adding the amount when the account is credited (money coming in)
- Subtracting the amount when the account is debited (money going out)
- Returning 0 if there are no transactions for the account

For budget categories (which are equity accounts), a positive balance means you have money available to spend, while a negative balance indicates overspending.
