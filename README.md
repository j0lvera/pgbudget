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

### Amount Representation

pgbudget stores all monetary amounts as integers (cents) using PostgreSQL's `bigint` type:
- $10.00 is stored as `1000` (1000 cents)
- $200.50 is stored as `20050` (20050 cents)

This approach avoids floating-point precision issues when dealing with money. It's the responsibility of the frontend/client application to format these values appropriately for display (e.g., dividing by 100 and adding decimal points, thousand separators, or currency symbols).

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

### Create a Checking Account

```sql
-- Create a checking account (asset type)
SELECT api.add_account(
    1,                          -- ledger_id
    'Checking',                 -- name
    'asset'                     -- type
) AS account_id;
```

Result:
```
 account_id 
-----------
         4
```

The `api.add_account` function simplifies creating accounts by automatically setting the correct internal type. It takes these parameters:
- `ledger_id`: The ID of your budget ledger
- `name`: The name of the account to create
- `type`: The account type ('asset', 'liability', or 'equity')

It returns the ID of the newly created account.

### Add Income

```sql
-- Add income of $1000 from "Paycheck" (100000 cents)
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Paycheck',                 -- description
    'inflow',                   -- type
    100000,                     -- amount (100000 cents = $1000.00)
    4,                          -- account_id (Checking account)
    api.find_category(1, 'Income')  -- category_id
);
```

Result:
```
 add_transaction 
----------------
              1
```

### Create Categories

```sql
-- Create a new category using the add_category function
SELECT api.add_category(
    1,                          -- ledger_id
    'Groceries'                 -- name
) AS category_id;

SELECT api.add_category(
    1,                          -- ledger_id
    'Internet bill'             -- name
) AS category_id;
```

The `api.add_category` function simplifies creating budget categories by automatically setting the correct account type and internal type. It takes these parameters:
- `ledger_id`: The ID of your budget ledger
- `name`: The name of the category to create

It returns the ID of the newly created category account.

### Assign Money to Categories

```sql

-- Assign $200 to Groceries (20000 cents)
SELECT api.assign_to_category(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Budget: Groceries',        -- description
    20000,                      -- amount (20000 cents = $200.00)
    api.find_category(1, 'Groceries')  -- category_id
);

-- Assign $75 to Internet bill (7500 cents)
SELECT api.assign_to_category(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Budget: Internet',         -- description
    7500,                       -- amount (7500 cents = $75.00)
    api.find_category(1, 'Internet bill')  -- category_id
);
```

The `api.assign_to_category` function handles moving money from your Income account to specific budget categories. It takes these parameters:
- `ledger_id`: The ID of your budget ledger
- `date`: When the assignment occurs
- `description`: A description for the assignment
- `amount`: How much money to assign (must be positive)
- `category_id`: The category to assign money to

### Spend Money

```sql
-- Spend $15 on Milk from Groceries category (1500 cents)
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Milk',                     -- description
    'outflow',                  -- type
    1500,                       -- amount (1500 cents = $15.00)
    4,                          -- account_id (Checking account)
    api.find_category(1, 'Groceries')  -- category_id
);

-- Pay the entire Internet bill (7500 cents)
SELECT api.add_transaction(
    1,                          -- ledger_id
    NOW(),                      -- date
    'Monthly Internet',         -- description
    'outflow',                  -- type
    7500,                       -- amount (7500 cents = $75.00)
    4,                          -- account_id (Checking account)
    api.find_category(1, 'Internet bill')  -- category_id
);
```

### Check Budget Status

```sql
-- View budget status for all categories
SELECT * FROM data.budget_status;
```

Result:
```
 id |     account_name     | budgeted | activity | balance 
----+----------------------+----------+----------+---------
  5 | Groceries            |   20000  |   -1500  |  18500
  6 | Internet bill        |    7500  |   -7500  |      0
```

Note: All amounts are in cents (20000 = $200.00, -1500 = -$15.00, etc.). The frontend application is responsible for formatting these values with proper decimal places and currency symbols.

For a specific ledger:
```sql
-- View budget status for ledger ID 2
SELECT * FROM api.get_budget_status(2);
```

The budget status shows:
- **budgeted**: Money assigned to this category
- **activity**: Money spent from this category
- **balance**: Current available amount in the category

You can also view all accounts and their balances:

```sql
-- View all accounts and their balances
SELECT 
    a.name, 
    a.type, 
    (SELECT SUM(
        CASE 
            WHEN t.credit_account_id = a.id THEN t.amount 
            WHEN t.debit_account_id = a.id THEN -t.amount 
            ELSE 0 
        END
    ) FROM data.transactions t 
    WHERE t.credit_account_id = a.id OR t.debit_account_id = a.id) as balance
FROM data.accounts a
WHERE a.ledger_id = 1
ORDER BY a.type, a.name;
```

Result:
```
      name       |   type    | balance 
-----------------+-----------+---------
 Checking        | asset     |  91000
 Income          | equity    |  72500
 Groceries       | equity    |  18500
 Internet bill   | equity    |      0
 Unassigned      | equity    |      0
```

Note: Balance amounts are in cents (91000 = $910.00).

### Check Account Balances

```sql
-- Get the balance of a specific account
SELECT api.get_account_balance(
    1,                          -- ledger_id
    4                           -- account_id
) AS balance;
```

Result:
```
 balance 
---------
   87500
```

Note: Balance amount is in cents (87500 = $875.00).

The `api.get_account_balance` function calculates the current balance of any account, handling both asset-like and liability-like accounts correctly. It takes these parameters:
- `ledger_id`: The ID of your budget ledger
- `account_id`: The ID of the account to check

This function automatically applies the correct accounting logic based on the account's internal type:
- For asset-like accounts (e.g., checking accounts): debits increase balance, credits decrease balance
- For liability-like accounts (e.g., credit cards, budget categories): credits increase balance, debits decrease balance

This ensures that balances are always calculated correctly regardless of account type.

The `api.get_account_balance` function calculates the current balance of any account, handling both asset-like and liability-like accounts correctly. It takes these parameters:
- `ledger_id`: The ID of your budget ledger
- `account_id`: The ID of the account to check

This function automatically applies the correct accounting logic based on the account's internal type:
- For asset-like accounts (e.g., checking accounts): debits increase balance, credits decrease balance
- For liability-like accounts (e.g., credit cards, budget categories): credits increase balance, debits decrease balance

This ensures that balances are always calculated correctly regardless of account type.

### View Account Transactions

```sql
-- View transactions for a specific account
SELECT * FROM api.get_account_transactions(4);  -- Replace 4 with your account ID
```

Result:
```
        date        |   category    | description  |   type   | amount 
--------------------+---------------+--------------+----------+--------
 2025-04-01 20:00:00 | Groceries     | Milk         | outflow  |  -1500
 2025-04-01 19:30:00 | Internet bill | Monthly Internet | outflow  |  -7500
 2025-04-01 18:00:00 | Income        | Paycheck     | inflow   | 100000
```

Note: All amounts are in cents (100000 = $1000.00, -7500 = -$75.00, etc.).

The account transactions view shows:
- **date**: When the transaction occurred
- **category**: The budget category associated with the transaction
- **description**: The transaction description
- **type**: Whether money flowed into the account (inflow) or out of it (outflow)
- **amount**: The transaction amount (positive for inflows, negative for outflows)

You can also use the default view for a quick look at transactions in account ID 4:

```sql
-- View transactions for the default account
SELECT * FROM data.account_transactions;
```

## Contributing

We welcome contributions to pgbudget! Before contributing, please read our [Contributing Guidelines](CONTRIBUTING.md) which includes important information about licensing and the contribution process.

All contributions to this project are subject to the terms outlined in the contributing guidelines and will be licensed under the project's AGPL-3.0 license.

## License

pgbudget is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).

This means:
- You are free to use, modify, and distribute this software
- If you modify the software and provide it as a service over a network, you must make your modified source code available to users of that service
- All modifications must also be licensed under AGPL-3.0

We chose AGPL-3.0 to:
- Ensure that all improvements to pgbudget remain open source
- Prevent corporations from using our code in closed-source proprietary products
- Prevent corporations from offering pgbudget as a service without contributing back to the open source project

For the full license text, see the [LICENSE](LICENSE) file in this repository or visit [GNU AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.en.html).
