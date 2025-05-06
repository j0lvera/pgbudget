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

All API interactions should use UUIDs to identify resources like ledgers, accounts, and categories.

### Create a Budget (Ledger)

You create a new budget (referred to as a "ledger") by inserting into the `api.ledgers` view.

```sql
-- Create a new budget ledger
INSERT INTO api.ledgers (name) VALUES ('My Budget') RETURNING uuid;
```

Result (example):
```
   uuid
----------
 d3pOOf6t
```
Store this `uuid` as it will be used as the `ledger_uuid` in subsequent operations.

### Update a Ledger's Name

You can update a ledger's attributes, such as its name, via the `api.ledgers` view.

```sql
-- Update the name of an existing ledger
UPDATE api.ledgers
   SET name = 'My Updated Budget'
 WHERE uuid = 'd3pOOf6t' -- Use the UUID of the ledger you want to update
 RETURNING name;
```

Result:
```
        name         
---------------------
 My Updated Budget
```

### Create a Checking Account

Accounts (like bank accounts, credit cards, etc.) are created by inserting into the `api.accounts` view.

```sql
-- Create a checking account (asset type)
INSERT INTO api.accounts (ledger_uuid, name, type)
VALUES ('d3pOOf6t', 'Checking', 'asset') -- Use your ledger_uuid
RETURNING uuid;
```

Result (example):
```
   uuid
----------
 aK9sLp0Q
```
Store this `uuid` as it will be used as an `account_uuid`.

You can create accounts by inserting directly into the `api.accounts` view. This view handles the underlying logic. Required fields typically include:
- `ledger_uuid`: The UUID of your budget ledger.
- `name`: The name of the account.
- `type`: The account type ('asset', 'liability', or 'equity').
The insert operation will return the UUID of the newly created account.

### Add Income

Income is typically recorded as an "inflow" transaction using the `api.simple_transactions` view. This transaction increases the balance of an asset account (e.g., 'Checking') and credits the special 'Income' category.

```sql
-- Add income of $1000 from "Paycheck" (100000 cents)
-- For this example, let's say 'checking-account-uuid' is the UUID for your 'Checking' account.

INSERT INTO api.simple_transactions (
    ledger_uuid,
    date,
    description,
    type,
    amount,
    account_uuid,       -- The bank account receiving the money
    category_uuid       -- The 'Income' category
) VALUES (
    'd3pOOf6t', -- Your ledger_uuid
    NOW(),
    'Paycheck',
    'inflow',
    100000,             -- Amount in cents ($1000.00)
    'aK9sLp0Q', -- Your checking_account_uuid
    (SELECT uuid FROM api.accounts WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income' AND type = 'equity') -- Dynamically find Income category UUID
) RETURNING uuid;
```

Result (example):
```
   uuid
----------
 xY7zPqR2
```
For more details on transaction entry, see the "Transaction Entry Options" section below. To find UUIDs of existing categories (like the default 'Income' category, or categories you've previously created), you can query the `api.accounts` view. For example, to find the 'Income' category UUID for a specific ledger: `SELECT uuid FROM api.accounts WHERE ledger_uuid = 'your-ledger-uuid' AND name = 'Income' AND type = 'equity';`. The `api.add_category` function, detailed in the "Create Categories" section, returns the UUID immediately upon creation of a new category.

### Create Categories

Budget categories are created using the `api.add_category` function.

```sql
-- Create a new category using the add_category function
SELECT uuid FROM api.add_category(
    'd3pOOf6t', -- Your ledger_uuid
    'Groceries'
) AS category_uuid;

SELECT uuid FROM api.add_category(
    'd3pOOf6t', -- Your ledger_uuid
    'Internet bill'
) AS category_uuid;
```
The `api.add_category` function simplifies creating budget categories by automatically setting the correct account type and internal type. It takes these parameters:
- `ledger_uuid`: The UUID of your budget ledger.
- `name`: The name of the category to create.

It returns the UUID of the newly created category account (which you should store as `category_uuid`).

### Assign Money to Categories

The `api.assign_to_category` function handles moving money from your 'Income' account to specific budget categories.

```sql
-- Assign $200 to Groceries (20000 cents)
-- Let's assume 'your-groceries-category-uuid' is the UUID for your 'Groceries' category.
SELECT uuid FROM api.assign_to_category(
    'd3pOOf6t', -- Your ledger_uuid
    NOW(),                                  -- Date of assignment
    'Budget: Groceries',                    -- Description
    20000,                                  -- Amount in cents ($200.00)
    'your-groceries-category-uuid'          -- The UUID of the 'Groceries' category
) AS transaction_uuid;

-- Assign $75 to Internet bill (7500 cents)
-- Let's assume 'your-internet-bill-category-uuid' is the UUID for your 'Internet bill' category.
SELECT uuid FROM api.assign_to_category(
    'd3pOOf6t', -- Your ledger_uuid
    NOW(),
    'Budget: Internet',
    7500,                                   -- Amount in cents ($75.00)
    'your-internet-bill-category-uuid'      -- The UUID of the 'Internet bill' category
) AS transaction_uuid;
```

It takes these parameters:
- `ledger_uuid`: The UUID of your budget ledger.
- `date`: When the assignment occurs.
- `description`: A description for the assignment.
- `amount`: How much money to assign (must be positive, in cents).
- `category_uuid`: The UUID of the category to assign money to.

### Spend Money

Spending is recorded as an "outflow" transaction using the `api.simple_transactions` view. This decreases the balance of an asset account (e.g., 'Checking') and debits the relevant budget category.

```sql
-- Spend $15 on Milk from Groceries category (1500 cents)
-- Use your ledger_uuid, checking_account_uuid, and groceries_category_uuid.
INSERT INTO api.simple_transactions (
    ledger_uuid,
    date,
    description,
    type,
    amount,
    account_uuid,       -- The bank account money is spent from
    category_uuid       -- The budget category the spending is attributed to
) VALUES (
    'd3pOOf6t', -- Your ledger_uuid
    NOW(),
    'Milk',
    'outflow',
    1500,                                   -- Amount in cents ($15.00)
    'aK9sLp0Q', -- Your checking_account_uuid
    'your-groceries-category-uuid'          -- Your groceries_category_uuid
) RETURNING uuid;

-- Pay the entire Internet bill (7500 cents)
INSERT INTO api.simple_transactions (
    ledger_uuid,
    date,
    description,
    type,
    amount,
    account_uuid,
    category_uuid
) VALUES (
    'd3pOOf6t', -- Your ledger_uuid
    NOW(),
    'Monthly Internet',
    'outflow',
    7500,                                   -- Amount in cents ($75.00)
    'aK9sLp0Q', -- Your checking_account_uuid
    'your-internet-bill-category-uuid'      -- Your internet_bill_category_uuid
) RETURNING uuid;
```

### Check Budget Status

```sql
-- View budget status for all categories in a specific ledger
-- This example uses a hypothetical api.get_budget_status function.
-- Alternatively, you might query a view like api.budget_status(ledger_uuid).
-- If querying data directly (for reads, using an example ledger_uuid):
SELECT * FROM data.budget_status WHERE ledger_id = (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t');
```

Example Result (from `data.budget_status` or a similar API view/function):
```
 id |     account_name     | budgeted | activity | balance 
----+----------------------+----------+----------+---------
  5 | Groceries            |   20000  |   -1500  |  18500
  6 | Internet bill        |    7500  |   -7500  |      0
```
(Assuming `id` here refers to an internal account ID; an API view might expose account UUIDs instead).

Note: All amounts are in cents (20000 = $200.00, -1500 = -$15.00, etc.).

For a specific ledger using an API function (if available):
```sql
-- View budget status for a ledger using its UUID (example ledger_uuid)
SELECT * FROM api.get_budget_status('d3pOOf6t'); -- Use your ledger_uuid
```

The budget status shows:
- **budgeted**: Money assigned to this category
- **activity**: Money spent from this category
- **balance**: Current available amount in the category

You can also view all accounts and their balances (example of direct data query for reads):
```sql
-- View all accounts and their balances for a specific ledger
SELECT 
    a.uuid as account_uuid, -- Exposing UUID
    a.name, 
    a.type, 
    (SELECT SUM(
        CASE 
            WHEN t.credit_account_id = a.id THEN t.amount 
            WHEN t.debit_account_id = a.id THEN -t.amount 
            ELSE 0 
        END
    ) FROM data.transactions t 
    WHERE (t.credit_account_id = a.id OR t.debit_account_id = a.id) -- Ensure transaction involves the account
      AND t.ledger_id = (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t') -- Filter by ledger
    ) as balance
FROM data.accounts a
WHERE a.ledger_id = (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t') -- Filter accounts by ledger
ORDER BY a.type, a.name;
```

Result (example):
```
 account_uuid |      name       |  type   | balance 
--------------+-----------------+---------+---------
 aK9sLp0Q     | Checking        | asset   |  91000
 zKHL0bud     | Income          | equity  |  72500
 qRZ6vwSL     | Groceries       | equity  |  18500
 2bkJFTjy     | Internet bill   | equity  |      0
 YJoetziG     | Unassigned      | equity  |      0
```
Note: Balance amounts are in cents (91000 = $910.00).

### Check Account Balances

```sql
-- Get the balance of a specific account using its UUID
SELECT balance FROM api.get_account_balance(
    'd3pOOf6t', -- Your ledger_uuid
    'aK9sLp0Q'  -- The account_uuid you want to check (example: Checking account)
) AS balance;
```

Result (example):
```
 balance 
---------
   87500
```
Note: Balance amount is in cents (87500 = $875.00).

The `api.get_account_balance` function calculates the current balance of any account. It takes these parameters:
- `ledger_uuid`: The UUID of your budget ledger.
- `account_uuid`: The UUID of the account to check.

This function automatically applies the correct accounting logic based on the account's internal type.

## Transaction Entry Options

pgbudget provides two methods for entering transactions, catering to different user preferences and knowledge levels:

### 1. Simple Transactions View (Recommended for Most Users)

```sql
-- Add a transaction using the simplified view
INSERT INTO api.simple_transactions (
    ledger_uuid,
    date,
    description,
    type,                      -- 'inflow' or 'outflow'
    amount,                    -- in cents (5000 = $50.00)
    account_uuid,              -- the bank account or credit card UUID
    category_uuid              -- the budget category UUID
) VALUES (
    'your-ledger-uuid',
    NOW(),
    'Grocery shopping',
    'outflow',
    5000,                      -- 5000 cents = $50.00
    'your-checking-account-uuid',
    'your-groceries-category-uuid'
) RETURNING uuid;

-- Update a transaction
UPDATE api.simple_transactions
   SET amount = 6000,          -- 6000 cents = $60.00
       description = 'Updated grocery shopping'
 WHERE uuid = 'your-transaction-uuid'; -- Use the UUID of the transaction to update
```

This approach:
- Uses intuitive concepts like "inflow" and "outflow"
- Automatically determines which accounts to debit and credit
- Shields users from needing to understand double-entry accounting details
- Supports full CRUD operations (insert, update, delete) with the same simplified interface
- Is exposed via PostgREST as a standard RESTful resource

### 2. Direct Transactions View (For Accounting Professionals)

```sql
-- Add a transaction by directly specifying debit and credit accounts
INSERT INTO api.transactions (
    ledger_uuid,
    description,
    date,
    amount,
    debit_account_uuid,
    credit_account_uuid
) VALUES (
    'your-ledger-uuid',
    'Grocery shopping',
    NOW(),
    5000,                       -- 5000 cents = $50.00
    'your-groceries-category-uuid',  -- account UUID to debit
    'your-checking-account-uuid'     -- account UUID to credit
) RETURNING uuid;
```

This approach:
- Gives complete control over the double-entry accounting process
- Requires understanding which account to debit and which to credit
- Is useful for complex transactions or for users familiar with accounting principles
- Follows standard PostgreSQL table operations

Both methods maintain the integrity of your double-entry accounting system while offering flexibility based on your comfort level with accounting concepts. The `simple_transactions` view is particularly useful for applications where users shouldn't need to understand accounting principles to manage their budget effectively.

### View Account Transactions

```sql
-- View transactions for a specific account using its UUID
SELECT * FROM api.get_account_transactions('your-account-uuid');
```

Result (example):
```
    date    |   category    |   description    |   type   | amount | balance
------------+---------------+------------------+----------+--------+--------
 2025-04-06 | Groceries     | Buy Groceries    | outflow  |   5000 | 492000
 2025-04-06 | Income        | Commission Income| inflow   |  10000 | 497000
 2025-04-05 | Internet      | Pay Internet Bill| outflow  |   9000 | 487000
 2025-04-05 | Groceries     | Buy Milk         | outflow  |   4000 | 496000
 2025-04-05 | Income        | Paycheck         | inflow   | 500000 | 500000
```

Note: All amounts are in cents (500000 = $5000.00, 4000 = $40.00, etc.).

The `api.get_account_transactions` function provides a comprehensive view of all transactions affecting a specific account, with the following information:

- **date**: The date when the transaction occurred
- **category**: The budget category or account associated with the transaction
- **description**: The transaction description
- **type**: Whether money flowed into the account (inflow) or out of it (outflow)
- **amount**: The transaction amount (always positive, with the direction indicated by the type)
- **balance**: The account balance after this transaction (running balance)

The function automatically handles the display logic based on the account type. Transactions are sorted by date (newest first) and then by creation time (newest first) to maintain a logical sequence.

You can also use the default view for a quick look at transactions in account ID 4 (if you know the internal ID and have direct data access):
```sql
-- View transactions for the account with internal ID 4
SELECT * FROM data.account_transactions WHERE account_id = 4;
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
