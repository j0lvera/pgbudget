# pgbudget

A PostgreSQL-based zero-sum budgeting database engine.

## Description

pgbudget is a robust database foundation for zero-sum budgeting applications. It provides a complete double-entry accounting system built on PostgreSQL, designed to serve as the database layer for budgeting microservices and applications.

## Current Status: Developer Preview (v0.1)

This release is targeted at developers who want a solid, well-tested database foundation for building budgeting applications.

### ✅ Core Features Available

**Budgeting Functionality:**
- ✅ Create ledgers (budgets) with proper isolation
- ✅ Create accounts (checking, savings, credit cards)
- ✅ Create budget categories with automatic setup
- ✅ Add income transactions with proper accounting
- ✅ Assign money from income to categories (budgeting process)
- ✅ Record spending transactions with category tracking
- ✅ View comprehensive budget status (budgeted vs spent per category)
- ✅ View account transaction history
- ✅ On-demand balance calculations for any account
- ✅ Complete double-entry accounting with full audit trail

**Technical Strengths:**
- ✅ Robust PostgreSQL-based architecture with proper schemas
- ✅ Comprehensive test coverage with real-world scenarios
- ✅ Clean API design with proper separation of concerns (`data`, `utils`, `api` schemas)
- ✅ Zero-sum budgeting principles correctly implemented
- ✅ Row-level security for multi-tenant usage
- ✅ Optimized queries with proper indexing

### 🚀 Roadmap

**Phase 1 Enhancements (Near-term):**
- 📋 Running balances in transaction history (currently TODO)
- 📋 Batch transaction operations for better performance
- 📋 Enhanced reporting functions (spending trends, category analysis)
- 📋 Data validation improvements and better error messages
- 📋 Performance optimizations for large transaction volumes

**Phase 2 Features (Future):**
- 📋 Recurring transaction templates
- 📋 Advanced transaction categorization and tagging
- 📋 Multi-currency support with exchange rates
- 📋 Budgeting goals and targets with progress tracking
- 📋 Data import/export utilities (CSV, JSON)
- 📋 Advanced analytics and reporting functions

**Explicitly Out of Scope:**
- ❌ Web interface (use separate frontend projects)
- ❌ User authentication (handled by application layer)
- ❌ REST API endpoints (direct database access)
- ❌ Mobile applications (build on top of this database)

This project focuses solely on providing a rock-solid database foundation. Authentication, user interfaces, and API layers are intended to be built as separate microservices on top of this database engine.

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

**⚠️ Important: Always Set User Context First**

Before running any queries, you must set the user context for the session. This is required for Row Level Security (RLS) to work properly:

```sql
-- Set the user context (replace 'your_user_id' with your actual user ID)
SELECT set_config('app.current_user_id', 'your_user_id', false);
```

### Create a Budget (Ledger)

You create a new budget (referred to as a "ledger") by inserting into the `api.ledgers` view.

```sql
-- Set user context first
SELECT set_config('app.current_user_id', 'your_user_id', false);

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

Income is recorded as an "inflow" transaction using the `api.transactions` view. This increases your bank account balance and credits the 'Income' category, making funds available for budgeting.

```sql
-- Add income of $1000 from "Paycheck" (100000 cents)
INSERT INTO api.transactions (
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
    (SELECT uuid FROM api.accounts WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income' AND type = 'equity')
) RETURNING uuid;
```

Result (example):
```
   uuid
----------
 xY7zPqR2
```

To find the Income category UUID for your ledger:
```sql
SELECT uuid FROM api.accounts 
WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income' AND type = 'equity';
```

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

Spending is recorded as an "outflow" transaction using the `api.transactions` view. This decreases your bank account balance and debits the relevant budget category.

```sql
-- Spend $15 on Milk from Groceries category (1500 cents)
INSERT INTO api.transactions (
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
INSERT INTO api.transactions (
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

Use the `api.get_budget_status` function to see how much you've budgeted, spent, and have remaining in each category:

```sql
-- Get budget status for all categories in a specific ledger
SELECT * FROM api.get_budget_status('d3pOOf6t');
```

Example Result:
```
 category_uuid |     category_name     | budgeted | activity | balance 
--------------+----------------------+----------+----------+---------
 aK9sLp0Q     | Groceries            |   20000  |   -1500  |  18500
 zKHL0bud     | Internet bill        |    7500  |   -7500  |      0
 mN8xPqR3     | Income               |        0 |        0 |  72500
```
Note: All amounts are in cents (20000 = $200.00, -1500 = -$15.00, etc.).

#### Understanding Budget Status

The budget status provides a snapshot of your financial plan and its execution. Each column has a specific meaning:

- **budgeted**: The total amount you've assigned to this category from your Income account. This represents your financial plan or intention.
- **activity**: The total spending (negative) or income (positive) in this category involving real-world accounts (assets or liabilities). This shows your actual financial behavior.
- **balance**: The current available amount in the category (effectively budgeted + activity). This is what you have left to spend.

#### How Budget Status is Calculated

1. **budgeted**: Sum of all transactions where money moves from 'Income' to this category
2. **activity**: Sum of all transactions between this category and any asset/liability account
3. **balance**: Net sum of all transactions involving this category (from any account)

#### Example Scenario

Let's follow a simple budget through several transactions:

1. **Receive Income**: $1000 paycheck
   ```sql
   -- Add income of $1000 to checking account
   INSERT INTO api.transactions (
       ledger_uuid, date, description, type, amount, account_uuid, category_uuid
   ) VALUES (
       'your-ledger-uuid', NOW(), 'Paycheck', 'inflow', 100000, 
       'your-checking-account-uuid', 'your-income-category-uuid'
   );
   ```
   - Increases your checking account by $1000
   - Increases your Income category by $1000
   - Budget status: Income has $1000 available to assign

2. **Budget Money**: Assign $200 to Groceries
   ```sql
   SELECT uuid FROM api.assign_to_category(
       'your-ledger-uuid', NOW(), 'Budget: Groceries', 20000, 'your-groceries-category-uuid'
   );
   ```
   - Decreases Income by $200
   - Increases Groceries by $200
   - Budget status: Groceries shows $200 budgeted, $0 activity, $200 balance

3. **Spend Money**: Spend $50 on groceries
   ```sql
   INSERT INTO api.transactions (
       ledger_uuid, date, description, type, amount, account_uuid, category_uuid
   ) VALUES (
       'your-ledger-uuid', NOW(), 'Grocery shopping', 'outflow', 5000,
       'your-checking-account-uuid', 'your-groceries-category-uuid'
   );
   ```
   - Decreases your checking account by $50
   - Decreases your Groceries category by $50
   - Budget status: Groceries now shows $200 budgeted, -$50 activity, $150 balance

Your budget status would now show:
```
 category_uuid |     category_name     | budgeted | activity | balance 
--------------+----------------------+----------+----------+---------
 aK9sLp0Q     | Groceries            |   20000  |   -5000  |  15000
 zKHL0bud     | Income               |       0  |       0  |  80000
```

This shows you've assigned $200 to Groceries, spent $50, and have $150 left to spend. Your Income category shows $800 remaining to be assigned to other categories.

#### Budget Status Flow Diagram

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│             │         │             │         │             │
│   Income    │         │  Category   │         │   Asset     │
│  (Equity)   │         │  (Equity)   │         │  Account    │
│             │         │             │         │             │
└──────┬──────┘         └──────┬──────┘         └──────┬──────┘
       │                        │                       │
       │                        │                       │
       │    Budget Money        │      Spend Money      │
       │  ────────────────>     │  ────────────────>    │
       │                        │                       │
       │                        │                       │
       │                        │                       │
       │                        │                       │
       │       Receive Income   │                       │
       │  <────────────────     │                       │
       │                        │                       │
       │                        │                       │
       ▼                        ▼                       ▼
  Decreases when          Increases when          Decreases when
  budgeting money         budgeting money         spending money
  
  Increases when          Decreases when          Increases when
  receiving income        spending money          receiving income
```

This diagram illustrates how money flows between accounts and affects your budget status.

## Complete Budget Setup Example

Here's a complete example that demonstrates setting up a budget with transactions and using the reporting functions:

```sql
DO $$
DECLARE
    v_user_id text := 'my_user_123';  -- Replace with your user ID
    v_ledger_uuid text;
    v_checking_uuid text;
    v_groceries_uuid text;
    v_income_uuid text;
    v_transaction_uuid text;
BEGIN
    -- Set user context
    PERFORM set_config('app.current_user_id', v_user_id, false);
    
    -- Create ledger
    INSERT INTO api.ledgers (name) 
    VALUES ('My Complete Budget') 
    RETURNING uuid INTO v_ledger_uuid;
    
    RAISE NOTICE 'Created ledger: %', v_ledger_uuid;
    
    -- Create checking account
    INSERT INTO api.accounts (ledger_uuid, name, type)
    VALUES (v_ledger_uuid, 'Checking', 'asset')
    RETURNING uuid INTO v_checking_uuid;
    
    -- Create groceries category
    SELECT uuid INTO v_groceries_uuid 
    FROM api.add_category(v_ledger_uuid, 'Groceries');
    
    -- Find income category (created automatically)
    SELECT utils.find_category(v_ledger_uuid, 'Income') INTO v_income_uuid;
    
    -- Add income transaction
    INSERT INTO api.transactions (
        ledger_uuid, date, description, type, amount, 
        account_uuid, category_uuid
    )
    VALUES (
        v_ledger_uuid, NOW(), 'Paycheck', 'inflow', 100000,
        v_checking_uuid, v_income_uuid
    )
    RETURNING uuid INTO v_transaction_uuid;
    
    -- Assign money to groceries
    SELECT uuid INTO v_transaction_uuid
    FROM api.assign_to_category(
        v_ledger_uuid, NOW(), 'Budget: Groceries', 
        30000, v_groceries_uuid
    );
    
    -- Spend money: Buy Milk
    INSERT INTO api.transactions (
        ledger_uuid, date, description, type, amount,
        account_uuid, category_uuid
    )
    VALUES (
        v_ledger_uuid, NOW(), 'Buy Milk', 'outflow', 500,
        v_checking_uuid, v_groceries_uuid
    )
    RETURNING uuid INTO v_transaction_uuid;
    
    -- Spend money: Buy Bread
    INSERT INTO api.transactions (
        ledger_uuid, date, description, type, amount,
        account_uuid, category_uuid
    )
    VALUES (
        v_ledger_uuid, NOW(), 'Buy Bread', 'outflow', 300,
        v_checking_uuid, v_groceries_uuid
    )
    RETURNING uuid INTO v_transaction_uuid;
    
    RAISE NOTICE 'Budget setup complete!';
    RAISE NOTICE 'Ledger: %, Checking: %, Groceries: %', 
        v_ledger_uuid, v_checking_uuid, v_groceries_uuid;
    
    -- Check account balance
    RAISE NOTICE 'Checking account balance: %', (
        SELECT utils.get_account_balance(
            (SELECT id FROM data.ledgers WHERE uuid = v_ledger_uuid),
            (SELECT id FROM data.accounts WHERE uuid = v_checking_uuid)
        )
    );
    
    -- View account transactions
    RAISE NOTICE 'Account transactions:';
    FOR v_transaction_uuid IN 
        SELECT date || ' - ' || category || ' - ' || description || ' - ' || type || ' - $' || (amount/100.0)
        FROM api.get_account_transactions(v_checking_uuid)
    LOOP
        RAISE NOTICE '%', v_transaction_uuid;
    END LOOP;
    
    -- View budget status
    RAISE NOTICE 'Budget status:';
    FOR v_transaction_uuid IN 
        SELECT category_name || ' - Budgeted: $' || (budgeted/100.0) || 
               ', Activity: $' || (activity/100.0) || ', Balance: $' || (balance/100.0)
        FROM api.get_budget_status(v_ledger_uuid)
    LOOP
        RAISE NOTICE '%', v_transaction_uuid;
    END LOOP;
END $$;
```

This example will:
1. Set up user context
2. Create a complete budget with ledger, checking account, and groceries category
3. Add income and assign money to groceries
4. Record two spending transactions (milk and bread)
5. Display account balance, transaction history, and budget status

### View All Account Balances

Get a comprehensive view of all accounts and their current balances:

```sql
-- View all accounts and their current balances for a specific ledger
SELECT
    a.uuid as account_uuid,
    a.name,
    a.type,
    utils.get_account_balance(
        (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t'),
        a.id
    ) as balance
FROM data.accounts a
WHERE a.ledger_id = (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t')
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

Get the current balance of any account using the on-demand balance calculation:

```sql
-- Get the current balance of a specific account
-- First, get the ledger_id and account_id
SELECT utils.get_account_balance(
    (SELECT id FROM data.ledgers WHERE uuid = 'd3pOOf6t'),
    (SELECT id FROM data.accounts WHERE uuid = 'aK9sLp0Q')
) AS balance;
```

Result (example):
```
 balance 
---------
   91000
```
Note: Balance amount is in cents (91000 = $910.00).

The balance is calculated on-demand by summing all transactions affecting the account, ensuring accuracy without maintaining separate balance tables.

### View Account Transactions

Use the `api.get_account_transactions` function to see the transaction history for any account:

```sql
-- View transactions for a specific account
SELECT * FROM api.get_account_transactions('aK9sLp0Q');
```

Example Result:
```
    date    |   category    |   description    |   type   | amount
------------+---------------+------------------+----------+--------
 2025-04-06 | Groceries     | Buy Groceries    | outflow  |   5000
 2025-04-06 | Income        | Commission Income| inflow   |  10000
 2025-04-05 | Internet      | Pay Internet Bill| outflow  |   9000
 2025-04-05 | Groceries     | Buy Milk         | outflow  |   4000
 2025-04-05 | Income        | Paycheck         | inflow   | 500000
```

Note: All amounts are in cents (500000 = $5000.00, 4000 = $40.00, etc.). Running balances are planned for a future release.

#### Understanding Account Transactions

The transaction view provides a complete history with user-friendly labels:

- **date**: When the transaction occurred
- **category**: For asset/liability accounts, shows the budget category. For category accounts, shows the asset/liability account involved.
- **description**: Your transaction description
- **type**: Simplified transaction type:
  - For asset accounts: "inflow" = money coming in, "outflow" = money going out
  - For liability accounts: "inflow" = debt increasing, "outflow" = debt decreasing  
  - For category accounts: "inflow" = budget increasing, "outflow" = budget decreasing
- **amount**: Transaction amount (always positive, direction shown by type)

Transactions are ordered by date (newest first) for easy review.

#### Transaction Type Logic

The system automatically determines transaction types based on:
1. The account's internal type (asset-like or liability-like)
2. Whether the account was debited or credited

This ensures intuitive display regardless of underlying accounting mechanics.

## Transaction Entry Options

The `api.transactions` view provides flexible transaction recording with two approaches:

### 1. Simplified Entry (Recommended)
Use `type`, `account_uuid`, and `category_uuid` for intuitive transaction recording:

```sql
-- Record spending using simplified entry
INSERT INTO api.transactions (
    ledger_uuid,
    date,
    description,
    type,                      -- 'inflow' or 'outflow'
    amount,                    -- in cents (5000 = $50.00)
    account_uuid,              -- the bank account or credit card UUID
    category_uuid              -- the budget category UUID
) VALUES (
    'd3pOOf6t',
    NOW(),
    'Grocery shopping',
    'outflow',
    5000,                      -- 5000 cents = $50.00
    'aK9sLp0Q',               -- checking account
    'your-groceries-category-uuid'
) RETURNING uuid;

-- Update a transaction
UPDATE api.transactions
   SET amount = 6000,          -- 6000 cents = $60.00
       description = 'Updated grocery shopping'
 WHERE uuid = 'your-transaction-uuid';
```

Benefits:
- Uses intuitive "inflow" and "outflow" concepts
- Automatically handles double-entry accounting
- Supports full CRUD operations
- No accounting knowledge required

### 2. Direct Debit/Credit Entry (Advanced)
For complete control, specify debit and credit accounts directly:

```sql
-- Record transaction with explicit debit/credit accounts
INSERT INTO api.transactions (
    ledger_uuid,
    description,
    date,
    amount,
    debit_account_uuid,         -- account to debit
    credit_account_uuid         -- account to credit
) VALUES (
    'd3pOOf6t',
    'Grocery shopping',
    NOW(),
    5000,                       -- 5000 cents = $50.00
    'your-groceries-category-uuid',  -- debit the category
    'aK9sLp0Q'                      -- credit the checking account
) RETURNING uuid;
```

Benefits:
- Complete control over double-entry process
- Useful for complex transactions
- Requires accounting knowledge


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
