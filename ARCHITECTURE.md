# Architecture Overview

This document outlines the architecture of the PGBudget application, focusing on its PostgreSQL database design which leverages zero-sum budgeting principles with double-entry accounting.

## 1. Introduction

PGBudget aims to provide a robust and auditable budgeting system. The architecture is centered around a PostgreSQL database, with specific schemas (`data`, `utils`, `api`) to organize tables, internal logic, and the public-facing API (exposed via PostgREST).

## 2. Core Concepts

The budgeting methodology is based on the `SPEC.md` document, which details:
-   **Zero-Sum Budgeting**: Every dollar of income is allocated to a budget category.
-   **Double-Entry Accounting**: All financial changes are recorded as transactions with debits and credits, ensuring the accounting equation (Assets = Liabilities + Equity) always balances.
-   **Account Types**:
    -   Bank Accounts (Asset)
    -   Credit Cards (Liability)
    -   Income (Equity - representing unallocated funds)
    -   Budget Categories (Equity - representing allocated funds)

## 3. Database Design

The database is structured into three main schemas: `data`, `utils`, and `api`.

### 3.1. `data` Schema

The `data` schema contains the core tables where all persistent information is stored. This includes ledgers, accounts, transactions, balances, etc. Direct access to this schema for mutations is generally discouraged for end-users; they should use the `api` schema functions instead.

Key characteristics:
-   **Tables**: Store the raw data (e.g., `data.ledgers`, `data.accounts`, `data.transactions`).
-   **Primary Keys**: Use `bigint generated always as identity`.
-   **UUIDs**: Publicly exposed identifiers are typically `text` (e.g., nanoid).
-   **RLS (Row Level Security)**: Enforced on tables to ensure users can only access and modify their own data. Policies typically check a `user_data` column against `utils.get_user()`. The `user_data` column in `data` tables is typically defined with `default utils.get_user()`, automatically populating it with the current user's identifier on insert and ensuring data ownership is recorded.
-   **Triggers**: Used for:
    -   Maintaining `updated_at` timestamps.
    -   Automated actions (e.g., `api.create_default_ledger_accounts` trigger on `data.ledgers` after insert).
    -   Calculating derived data (e.g., updating `data.balances` after a new transaction).
-   **Constraints**: Used to enforce data integrity (e.g., `check` constraints, `foreign key` constraints, `unique` constraints).

Example table definition (`data.ledgers` from `migrations/20250326192940_add_ledgers_table.sql`):
```sql
create table data.ledgers
(
    id          bigint generated always as identity primary key,
    uuid        text        not null default utils.nanoid(8),

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    metadata    jsonb,

    user_data   text        not null default utils.get_user(),

    constraint ledgers_uuid_unique unique (uuid),
    constraint ledgers_name_user_unique unique (name, user_data),
    constraint ledgers_name_length_check check (char_length(name) <= 255),
    -- ... other constraints
);

alter table data.ledgers enable row level security;
create policy ledgers_policy on data.ledgers
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());
```

### 3.2. `utils` Schema

The `utils` schema contains helper functions and utilities that are used internally by functions in the `api` schema or by triggers in the `data` schema. These functions are not typically exposed directly via the PostgREST API.

Key characteristics:
-   **Internal Logic**: Encapsulates complex, reusable, or sensitive SQL logic.
-   **Security Definer**: Many utility functions that need to operate on underlying `data` tables across different user contexts or perform privileged operations run with `SECURITY DEFINER`. This allows them to execute with the permissions of the function owner (a trusted role), not the calling user. This is crucial for tasks like creating records in `data` tables where the end-user (via `pgb_web_user`) might not have direct insert rights but is allowed to perform the action through a trusted `api` function.
-   **User Context**: Functions in `utils` often rely on `utils.get_user()` internally (especially when `SECURITY DEFINER`) to operate within the correct user's scope. They may also accept an explicit `p_user_data text default utils.get_user()` parameter. This provides flexibility for direct calls or testing scenarios where the user context needs to be explicitly passed, overriding the session's default derived from the JWT.
-   **Naming Convention**: Often follow `<table>_<action>_<type>` or a descriptive name.

Example: `utils.get_user()` (retrieves user ID from JWT claims set by PostgREST)
```sql
-- (Conceptual example from CONVENTIONS.md, actual implementation might be in an initial migration)
create or replace function utils.get_user() returns text as $$
begin
    -- Retrieves user identifier from PostgREST's JWT claims
    -- The 'true' argument means it will return NULL if the setting is not found,
    -- rather than raising an error.
    return current_setting('request.jwt.claims.user_data', true);
exception
    when undefined_object then
        -- This handles cases where the setting might not be defined at all,
        -- though current_setting with 'true' should prevent this specific exception.
        return null;
end;
$$ language plpgsql stable;
-- Note: The user_data claim is expected to be set in the JWT by the authentication service.
-- For testing, it's set manually: SELECT set_config('request.jwt.claims', '{"user_data": "test_user"}', false);
```

### 3.3. `api` Schema

The `api` schema is the primary interface for clients (e.g., a web application using PostgREST). It exposes views for reading data and functions for mutating data, adhering to the conventions in `CONVENTIONS.md`.

Key characteristics:
-   **Public Interface**: Defines the contract for how clients interact with the database. All objects in this schema are typically granted usage/execution rights to the `pgb_web_user` role.
-   **Security Invoker**: Functions and views in the `api` schema typically run with `SECURITY INVOKER` (the default for views, explicitly set for functions if needed, or default if not specified). This means they execute with the permissions of the calling user (`pgb_web_user`). RLS policies on the underlying `data` tables will therefore apply directly.
-   **Abstraction**: Hides the complexity of the `data` schema and internal `utils` functions. API functions orchestrate calls to `utils` functions.
-   **Business Logic**: Enforces high-level business rules and translates API calls into operations on the data layer, often via `utils` functions.
-   **Data Transformation**: Views can format data from `data` tables into a more client-friendly structure. Functions return types that match these view structures or defined composite types.
-   **Naming Convention**: Functions often follow `<table>_<action>_<type>` (e.g., `add_category`, `assign_to_category`). Parameters in API functions often use a `p_` prefix if there's a potential collision with column names in the return type, or if preferred for clarity.
-   **Column Exposure**: API views should selectively expose columns. Internal database identifiers (e.g., `id` of type `bigint`) and internal audit timestamps (e.g., `created_at`, `updated_at` from `data` tables) are generally not exposed directly in the API. Publicly visible `uuid`s (often `text`) are used for entity identification in the API. Timestamps relevant to the business domain (e.g., transaction `date`) are exposed.

**Common Patterns for API Functions:**

1.  **Calling `utils` then querying API view (Pattern A)**:
    *   The `api` function calls a `utils` function to perform the core data modification (e.g., inserting a record into a `data` table).
    *   The `utils` function returns some identifier of the created/modified record (e.g., its internal `id` or public `uuid`).
    *   The `api` function then uses this identifier to query the corresponding `api` view (e.g., `api.accounts`) to fetch and return the full record in the desired API format. This ensures the response structure is consistent with what clients would get if they queried the view directly.

2.  **Calling `utils` then constructing response from `utils` result and inputs (Pattern B)**:
    *   The `api` function calls a `utils` function.
    *   The `utils` function performs the core logic and returns multiple pieces of data necessary for the API response (e.g., UUID of a newly created transaction, UUIDs of related accounts, metadata).
    *   The `api` function then uses its own input parameters along with the data returned by the `utils` function to *construct* a record that matches the expected API response structure (e.g., matching an `api.transactions` view's columns). This can be more efficient if the `utils` function already has all or most of the necessary information, avoiding a second query to the database.

### 3.3.1. Making API Views Updatable (CRUD Operations)

While simple API views selecting directly from a single `data` table can often be made directly updatable by PostgREST for `INSERT`, `UPDATE`, and `DELETE` operations, many views are more complex. Views that involve joins, aggregations, or computed columns (like resolving internal foreign key IDs to public UUIDs) are not directly updatable.

To enable CRUD operations on such complex views via PostgREST, we use `INSTEAD OF` triggers. These triggers fire *instead of* the attempted `INSERT`, `UPDATE`, or `DELETE` operation on the view. The trigger function, typically residing in the `utils` schema, then performs the actual data manipulation on the underlying `data` tables. This often involves resolving UUIDs provided in the API call to their corresponding internal `bigint` IDs.

**Example: Updatable `api.transactions` View for Inserts**

Consider an `api.transactions` view designed to expose transaction details with related entity UUIDs:

```sql
-- api/views/transactions.sql (example path)
create or replace view api.transactions with (security_invoker = true) as
select t.uuid,
       t.description,
       t.amount,
       t.metadata,
       t.date,
       (select l.uuid from data.ledgers l where l.id = t.ledger_id)::text          as ledger_uuid,
       (select a.uuid from data.accounts a where a.id = t.debit_account_id)::text  as debit_account_uuid,
       (select a.uuid from data.accounts a where a.id = t.credit_account_id)::text as credit_account_uuid
  from data.transactions t;

-- Grant select access to the web user
-- GRANT SELECT ON api.transactions TO pgb_web_user;
```

To allow `INSERT` operations on this `api.transactions` view (e.g., `POST /transactions` via PostgREST), we define an `INSTEAD OF INSERT` trigger and its corresponding trigger function:

```sql
-- utils/transaction_triggers.sql (example path)
create or replace function utils.transactions_insert_single_fn()
returns trigger as
$$
declare
    v_ledger_id         bigint;
    v_debit_account_id  bigint;
    v_credit_account_id bigint;
    v_user_data         text := utils.get_user(); -- Capture user context
begin
    -- Resolve ledger_uuid to internal ledger_id
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid and l.user_data = v_user_data; -- Ensure ledger belongs to user

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- Resolve debit_account_uuid to internal debit_account_id
    select a.id
      into v_debit_account_id
      from data.accounts a
     where a.uuid = NEW.debit_account_uuid
       and a.ledger_id = v_ledger_id and a.user_data = v_user_data; -- Ensure account belongs to ledger and user

    if v_debit_account_id is null then
        raise exception 'Debit account with UUID % not found in ledger % for current user', NEW.debit_account_uuid, NEW.ledger_uuid;
    end if;

    -- Resolve credit_account_uuid to internal credit_account_id
    select a.id
      into v_credit_account_id
      from data.accounts a
     where a.uuid = NEW.credit_account_uuid
       and a.ledger_id = v_ledger_id and a.user_data = v_user_data; -- Ensure account belongs to ledger and user

    if v_credit_account_id is null then
        raise exception 'Credit account with UUID % not found in ledger % for current user', NEW.credit_account_uuid, NEW.ledger_uuid;
    end if;

    -- Insert the transaction into the base data.transactions table
    -- The user_data column in data.transactions will use its default (utils.get_user())
    -- or can be explicitly set to v_user_data if needed.
    insert into data.transactions (
        description, date, amount,
        debit_account_id, credit_account_id, ledger_id,
        metadata
        -- user_data will default to utils.get_user()
    )
    values (
        NEW.description, NEW.date, NEW.amount,
        v_debit_account_id, v_credit_account_id, v_ledger_id,
        NEW.metadata
    )
    -- Return the newly inserted row's relevant fields (matching the view's columns)
    -- so PostgREST can return the created resource.
    returning uuid, description, amount, metadata, date into
        NEW.uuid, NEW.description, NEW.amount, NEW.metadata, NEW.date;

    -- NEW.ledger_uuid, NEW.debit_account_uuid, NEW.credit_account_uuid are already set from the input.
    -- The trigger function must return NEW for INSERT/UPDATE triggers.
    return NEW;
end;
$$ language plpgsql volatile security definer; -- Security definer if it needs to bypass RLS temporarily for lookups,
                                           -- but user context is still checked.

-- Create the trigger on the API view
create trigger transactions_instead_of_insert_trigger
    instead of insert on api.transactions
    for each row execute function utils.transactions_insert_single_fn();

-- Grant insert access to the web user
-- GRANT INSERT ON api.transactions TO pgb_web_user;
```

**Notes on the `INSTEAD OF INSERT` pattern:**
-   The trigger function (`utils.transactions_insert_single_fn`) resolves the provided `ledger_uuid`, `debit_account_uuid`, and `credit_account_uuid` to their internal `bigint` IDs.
-   It performs necessary validations (e.g., ensuring accounts belong to the specified ledger and the current user).
-   It inserts the record into the actual `data.transactions` table.
-   It populates `NEW.uuid`, `NEW.description`, etc., with values from the newly inserted row (or input `NEW` values if they are part of the view and not generated during insert) so that PostgREST can return the representation of the created resource. The `ledger_uuid`, `debit_account_uuid`, and `credit_account_uuid` fields in `NEW` are already populated from the client's `INSERT` request to the view.
-   Similar `INSTEAD OF UPDATE` and `INSTEAD OF DELETE` triggers, along with their respective `utils` functions, would be required to provide full CRUD functionality on the `api.transactions` view.

This approach allows clients to interact with the API using user-friendly UUIDs for all entities, while the database internally manages relationships with `bigint` foreign keys. It's important to remember that when using the `utils` schema functions directly (bypassing the `api` views/triggers), the caller is responsible for providing correct internal IDs and adhering to double-entry patterns.

**Examples:**

-   A view for accessing ledgers (from `migrations/20250503172238_add_ledgers_api_fns.sql`):
    ```sql
    -- Example: API view for ledgers.
    -- This view allows SELECT operations. For INSERT/UPDATE/DELETE,
    -- INSTEAD OF triggers would typically call corresponding utils functions.
    create or replace view api.ledgers with (security_invoker = true) as
    select l.uuid,
           l.name,
           l.description,
           l.metadata,
           l.user_data -- Exposing user_data can be useful for clients to confirm ownership
                       -- or for specific RLS scenarios in more complex views.
      from data.ledgers l;

    -- Permissions are granted in migrations:
    -- grant select on api.ledgers to pgb_web_user;
    -- grant insert on api.ledgers to pgb_web_user; (if INSTEAD OF INSERT trigger exists)
    ```
    This view is simple enough that PostgREST can handle `INSERT` operations directly by mapping view columns to the underlying `data.ledgers` table columns. Required columns like `name` must be provided in the `INSERT` statement, while others like `uuid` and `user_data` will use their default values defined in `data.ledgers`. This is demonstrated in `main_test.go` with `INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid;`. For more complex views involving joins or transformations, `INSTEAD OF` triggers are necessary for `INSERT/UPDATE/DELETE` operations, as shown in the `api.transactions` example below.

-   A function for creating a new category, which calls a `utils` function and then returns the new category by querying the `api.accounts` view (Pattern A):
    ```sql
    -- Example: API function for adding a new budget category.
    -- It calls a utils function to perform the core logic (inserting into data.accounts)
    -- and then returns the newly created account by querying the api.accounts view.
    -- (Reflects implementation from migrations/20250402001314_add_category_fns.sql)

    -- First, the 'utils.add_category' function (internal logic):
    -- (This would reside in a utils schema file, e.g., utils/category_utils.sql)
    /*
    create or replace function utils.add_category(
        p_ledger_uuid text,
        p_name text,
        p_user_data text = utils.get_user()
    ) returns data.accounts as -- Returns the full internal account record
    $$
    declare
        v_ledger_id   int;
        v_account_record data.accounts;
    begin
        select l.id into v_ledger_id from data.ledgers l
        where l.uuid = p_ledger_uuid and l.user_data = p_user_data;

        if v_ledger_id is null then
            raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
        end if;

        if p_name is null or trim(p_name) = '' then
            raise exception 'Category name cannot be empty';
        end if;

        insert into data.accounts (ledger_id, name, type, internal_type, user_data)
        values (v_ledger_id, p_name, 'equity', 'liability_like', p_user_data)
        returning * into v_account_record;

        return v_account_record;
    end;
    $$ language plpgsql security definer;
    */

    -- Then, the 'api.add_category' function (publicly exposed):
    create or replace function api.add_category(
        ledger_uuid text, -- Note: p_ prefix not used here in actual migration, but good practice
        name text
    ) returns setof api.accounts as -- Returns a record matching the api.accounts view
    $$
    declare
        v_util_result data.accounts; -- Holds the full account record from utils.add_category
    begin
        -- Call the internal utility function to perform the insertion.
        -- utils.get_user() is implicitly used by utils.add_category for user context.
        v_util_result := utils.add_category(ledger_uuid, name);

        -- Return the newly created account by querying the corresponding API view.
        -- This ensures the output matches the view definition exactly.
        return query
        select *
        from api.accounts a -- Assuming api.accounts is a view
        where a.uuid = v_util_result.uuid; -- Filter for the created account's UUID

    end;
    $$ language plpgsql volatile security invoker; -- API function runs as invoker
    -- Grant execute on this function to pgb_web_user:
    -- GRANT EXECUTE ON FUNCTION api.add_category(text, text) TO pgb_web_user;
    ```

-   A function for assigning money to a category, which calls a `utils` function and then constructs the return value (Pattern B):
    ```sql
    -- Example: API function for assigning funds from 'Income' to a category.
    -- This corresponds to the "Budgeting Money" transaction in SPEC.MD.
    -- It calls a utils function to perform the core logic and then constructs
    -- the return value based on the utils result and input parameters,
    -- matching the structure of an `api.transactions` view/type.
    -- (Reflects implementation from migrations/20250402001314_add_category_fns.sql)

    -- First, the 'utils.assign_to_category' function (internal logic):
    -- (This would reside in a utils schema file, e.g., utils/category_utils.sql)
    /*
    create or replace function utils.assign_to_category(
        p_ledger_uuid text,
        p_date timestamptz,
        p_description text,
        p_amount bigint,
        p_category_uuid text, -- Target category UUID
        p_user_data text = utils.get_user()
    ) returns table(transaction_uuid text, income_account_uuid text, metadata jsonb) as
    $$
    declare
        v_ledger_id          int;
        v_income_account_id  int;
        v_income_account_uuid_local text; -- UUID of the 'Income' account
        v_category_account_id int;      -- Internal ID of the target category
        v_transaction_uuid_local text;  -- UUID of the created transaction
        v_metadata_local jsonb;
    begin
        -- find the ledger ID for the specified UUID and user
        select l.id into v_ledger_id from data.ledgers l
        where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
        if v_ledger_id is null then
            raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
        end if;

        -- validate amount is positive
        if p_amount <= 0 then
            raise exception 'Assignment amount must be positive: %', p_amount;
        end if;

        -- find the Income account ID and UUID for this ledger
        select a.id, a.uuid into v_income_account_id, v_income_account_uuid_local from data.accounts a
        where a.ledger_id = v_ledger_id and a.user_data = p_user_data and a.name = 'Income' and a.type = 'equity';
        if v_income_account_id is null then
            raise exception 'Income account not found for ledger %', v_ledger_id;
        end if;

        -- find the target category account ID
        select a.id into v_category_account_id from data.accounts a
        where a.uuid = p_category_uuid and a.ledger_id = v_ledger_id and a.user_data = p_user_data and a.type = 'equity';
        if v_category_account_id is null then
            raise exception 'Category with UUID % not found or does not belong to ledger % for current user', p_category_uuid, v_ledger_id;
        end if;

        -- create the transaction (debit Income, credit Category)
        insert into data.transactions (ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data)
        values (v_ledger_id, p_description, p_date, p_amount, v_income_account_id, v_category_account_id, p_user_data)
        returning uuid, metadata into v_transaction_uuid_local, v_metadata_local;

       return query select v_transaction_uuid_local, v_income_account_uuid_local, v_metadata_local;
    end;
    $$ language plpgsql volatile security definer;
    */

    -- Then, the 'api.assign_to_category' function (publicly exposed):
    create or replace function api.assign_to_category(
        p_ledger_uuid text,
        p_date timestamptz,
        p_description text,
        p_amount bigint, -- Amount in cents
        p_category_uuid text -- The UUID of the category to assign funds to
    ) returns setof api.transactions as -- Assuming api.transactions is a view or matches this structure
    $$
    declare
        v_util_result record; -- Stores result from utils.assign_to_category
                              -- (transaction_uuid, income_account_uuid, metadata)
    begin
        -- Call the internal utility function.
        -- utils.get_user() is implicitly used by utils.assign_to_category for user context.
        select * into v_util_result from utils.assign_to_category(
            p_ledger_uuid   := p_ledger_uuid,
            p_date          := p_date,
            p_description   := p_description,
            p_amount        := p_amount,
            p_category_uuid := p_category_uuid
        );

       -- Construct the return record using information from the utils function's result
       -- and the input parameters of this API function.
       -- This matches the structure expected by clients (e.g., api.transactions view).
       return query
       select
           v_util_result.transaction_uuid::text as uuid,
           p_description::text as description,
           p_amount::bigint as amount,
           v_util_result.metadata::jsonb as metadata,
           p_date::timestamptz as date,
           p_ledger_uuid::text as ledger_uuid,
           v_util_result.income_account_uuid::text as debit_account_uuid, -- 'Income' account is debited
           p_category_uuid::text as credit_account_uuid; -- Target category is credited
    end;
    $$ language plpgsql volatile security invoker; -- API function runs as invoker
    -- Grant execute on this function to pgb_web_user:
    -- GRANT EXECUTE ON FUNCTION api.assign_to_category(text, timestamptz, text, bigint, text) TO pgb_web_user;
    ```

## 4. PostgREST Integration

PostgREST is used to expose the `api` schema (and parts of `data` schema for reads if configured) as a RESTful API.
-   `pgb_web_user` role is used by PostgREST to connect to the database. This role has minimal privileges, typically `USAGE` on schemas and `SELECT` on specific `api` views, and `EXECUTE` on `api` functions.
-   JWT (JSON Web Tokens) are used for authentication. PostgREST validates the JWT and sets session variables like `request.jwt.claims.user_data`, which are then used by `utils.get_user()` and RLS policies.

## 5. Migrations

Database schema changes are managed using `goose`. Migrations are written in SQL and stored in the `migrations` directory. Each migration has an `Up` and a `Down` section.

Conventions:
-   SQL queries in lowercase.
-   Comments above SQL statements.
-   Use `bigint generated always as identity` for primary keys.
-   Table constraints preferred over column constraints.
-   Constraint naming: `<table>_<column>_<constraint>_<type>`.

This architecture aims for a secure, maintainable, and extensible system for zero-sum budgeting.
