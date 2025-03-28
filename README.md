# Zero-Sum Budget

A double-entry accounting system for zero-sum budgeting.

## Setup

1. Initialize the database
2. Run migrations

## Usage Examples

### Create a Budget (Ledger)

```sql
SELECT api.create_ledger('My Budget');
```

Result:
```
 create_ledger 
--------------
 1
```

### Add Income

```sql
-- Add income of $1000 from "Paycheck"
SELECT api.record_income(1, 'Paycheck', 1000.00);
```

Result:
```
 record_income 
--------------
 1
```

### Assign Money to Categories

```sql
-- Assign $200 to Groceries
SELECT api.assign_to_category(1, 'Groceries', 200.00);

-- Assign $75 to Internet bill
SELECT api.assign_to_category(1, 'Internet bill', 75.00);
```

Result:
```
 assign_to_category 
-------------------
 2
```

```
 assign_to_category 
-------------------
 3
```

### Spend Money

```sql
-- Spend $15 on Milk from Groceries category
SELECT api.record_expense(1, 'Groceries', 'Milk', 15.00);

-- Pay the entire Internet bill
SELECT api.record_expense(1, 'Internet bill', 'Monthly Internet', 75.00);
```

Result:
```
 record_expense 
---------------
 4
```

```
 record_expense 
---------------
 5
```

### Check Budget Status

```sql
-- View all accounts and their balances
SELECT 
    a.name, 
    a.type, 
    a.balance
FROM data.accounts a
WHERE a.ledger_id = 1
ORDER BY a.type, a.name;
```

Result:
```
      name       |   type    | balance 
-----------------+-----------+---------
 Checking        | asset     |  910.00
 Income          | equity    |  725.00
 Groceries       | equity    |  185.00
 Internet bill   | equity    |    0.00
```

```sql
-- View all transactions
SELECT 
    t.description, 
    t.amount, 
    da.name as debit_account, 
    ca.name as credit_account,
    t.created_at
FROM data.transactions t
JOIN data.accounts da ON t.debit_account_id = da.id
JOIN data.accounts ca ON t.credit_account_id = ca.id
WHERE da.ledger_id = 1
ORDER BY t.created_at;
```

Result:
```
  description   | amount | debit_account | credit_account |        created_at        
----------------+--------+---------------+----------------+---------------------------
 Paycheck       | 1000.00| Checking      | Income         | 2023-04-01 10:00:00+00
 Budget: Groceries| 200.00| Income        | Groceries      | 2023-04-01 10:05:00+00
 Budget: Internet| 75.00 | Income        | Internet bill  | 2023-04-01 10:10:00+00
 Milk           | 15.00  | Groceries     | Checking       | 2023-04-02 15:30:00+00
 Monthly Internet| 75.00 | Internet bill | Checking       | 2023-04-05 09:00:00+00
```
