# pgbudget

A PostgreSQL-based zero-sum budgeting system.

## Description

pgbudget lets you manage your personal budget directly in PostgreSQL. It helps you track income, assign money to categories, and record expenses while maintaining balance across all accounts.

## Requirements

- PostgreSQL 12 or higher
- [Goose](https://github.com/pressly/goose) for database migrations

## Default Accounts

When creating a new ledger, the system automatically creates three special accounts:

- **Income**: Holds your unallocated funds until you assign them to specific categories
- **Off-budget**: For transactions you want to track but not include in your budget
- **Unassigned**: Default category for transactions without a specified category

These accounts are essential to the zero-sum budgeting system. As explained in [Zero-Sum Budgeting with Double-Entry Accounting](https://jolvera.com/zero-sum-budgeting-with-double-entry-accounting/), categories (including Income) function as equity accounts rather than expense accounts because they track what you can spend, not what you've spent. Income serves as "unassigned equity" while budget categories represent "assigned equity." Budgeting is simply the process of moving money from unassigned to assigned status.

## Setup

1. Create a PostgreSQL database for your budget
2. Run migrations using Goose:

```bash
goose -dir migrations postgres "user=username password=password dbname=pgbudget sslmode=disable" up
```

For more configuration options, refer to the [Goose documentation](https://github.com/pressly/goose).

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
    api.find_category(1, 'Income')  -- category_id
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
    api.find_category(1, 'Income'),  -- account_id
    api.find_category(1, 'Groceries')  -- category_id
);

-- Assign $75 to Internet bill
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Budget: Internet',         -- description
    'outflow',                  -- type
    75.00,                      -- amount
    api.find_category(1, 'Income'),  -- account_id
    api.find_category(1, 'Internet bill')  -- category_id
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
    api.find_category(1, 'Groceries')  -- category_id
);

-- Pay the entire Internet bill
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Monthly Internet',         -- description
    'outflow',                  -- type
    75.00,                      -- amount
    1,                          -- account_id (Checking account)
    api.find_category(1, 'Internet bill')  -- category_id
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
