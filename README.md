# pgbudget

A PostgreSQL-based double-entry accounting system for zero-sum budgeting.

## Description

pgbudget lets you manage your personal budget directly in PostgreSQL using double-entry accounting principles. It helps you track income, assign money to categories, and record expenses while maintaining balance across all accounts.

## Setup

1. Initialize the database
2. Run migrations

## Usage Examples

### Create a Budget (Ledger)

```sql
-- Create a new budget ledger
INSERT INTO data.ledgers (name) VALUES ('My Budget') RETURNING id;
```

Result:
```
 id 
----
  1
```

### Add Income

```sql
-- Add income of $1000 from "Paycheck"
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Paycheck',                 -- description
    'inflow',                   -- type
    1000.00,                    -- amount
    1,                          -- account_id (Checking account)
    (SELECT id FROM data.accounts WHERE name = 'Income' AND ledger_id = 1)  -- category_id
);
```

Result:
```
 add_transaction 
----------------
              1
```

### Assign Money to Categories

```sql
-- First create the category accounts
INSERT INTO data.accounts (ledger_id, name, type, internal_type) 
VALUES (1, 'Groceries', 'equity', 'liability_like') RETURNING id;

INSERT INTO data.accounts (ledger_id, name, type, internal_type) 
VALUES (1, 'Internet bill', 'equity', 'liability_like') RETURNING id;

-- Assign $200 to Groceries
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Budget: Groceries',        -- description
    'outflow',                  -- type
    200.00,                     -- amount
    (SELECT id FROM data.accounts WHERE name = 'Income' AND ledger_id = 1),  -- account_id
    (SELECT id FROM data.accounts WHERE name = 'Groceries' AND ledger_id = 1)  -- category_id
);

-- Assign $75 to Internet bill
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Budget: Internet',         -- description
    'outflow',                  -- type
    75.00,                      -- amount
    (SELECT id FROM data.accounts WHERE name = 'Income' AND ledger_id = 1),  -- account_id
    (SELECT id FROM data.accounts WHERE name = 'Internet bill' AND ledger_id = 1)  -- category_id
);
```

### Spend Money

```sql
-- Spend $15 on Milk from Groceries category
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Milk',                     -- description
    'outflow',                  -- type
    15.00,                      -- amount
    1,                          -- account_id (Checking account)
    (SELECT id FROM data.accounts WHERE name = 'Groceries' AND ledger_id = 1)  -- category_id
);

-- Pay the entire Internet bill
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Monthly Internet',         -- description
    'outflow',                  -- type
    75.00,                      -- amount
    1,                          -- account_id (Checking account)
    (SELECT id FROM data.accounts WHERE name = 'Internet bill' AND ledger_id = 1)  -- category_id
);
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
 Unassigned      | equity    |    0.00
```

```sql
-- View all transactions
SELECT 
    t.description, 
    t.amount, 
    da.name as debit_account, 
    ca.name as credit_account,
    t.date
FROM data.transactions t
JOIN data.accounts da ON t.debit_account_id = da.id
JOIN data.accounts ca ON t.credit_account_id = ca.id
WHERE da.ledger_id = 1
ORDER BY t.date;
```
