# CRUSH Configuration

## Build/Test Commands
- **Run all tests**: `go test -v ./...`
- **Run single test**: `go test -v -run TestName`
- **Run tests with coverage**: `go test -v -cover ./...`
- **Build**: `go build`
- **Format code**: `go fmt ./...`
- **Lint**: `go vet ./...`
- **Tidy dependencies**: `go mod tidy`

## Database Commands (via Task)
- **Run migrations**: `task migrate:up`
- **Create migration**: `task migrate:new -- migration_name`
- **Migration status**: `task migrate:status`
- **Rollback migration**: `task migrate:down`

## Code Style Guidelines

### PostgreSQL Conventions
- Write SQL queries in lowercase (strings can be any case)
- Always add comments above SQL queries explaining each step
- Use `data` schema for data shape definitions
- Use `api` schema for functions that modify data
- Use `utils` schema for internal utility functions
- Primary keys: `bigint generated always as identity`
- Prefer table constraints over column constraints
- Constraint naming: `<table>_<column>_<constraint>_<type>`

### Schema Separation Pattern
**CRITICAL**: Always follow this separation of concerns between schemas:

**`api` schema (Public Interface):**
- Functions take UUID parameters (user-friendly)
- Thin wrappers that call `utils` functions
- Convert UUIDs to text and pass to utils
- Convert returned IDs back to UUIDs
- Minimal business logic - just parameter conversion
- Example: `api.add_transaction(uuid, text, uuid)` → calls `utils.add_transaction(text, text, text)`

**`utils` schema (Internal Business Logic):**
- Functions take text parameters (for legacy UUID compatibility)
- Handle all UUID→ID conversion internally
- Contain all business logic (validation, double-entry rules, etc.)
- Work with internal IDs (bigint) for database operations
- Handle special cases like "Unassigned" category lookup
- Return IDs (int/bigint) to api functions

**`data` schema (Raw Data):**
- Tables and basic constraints only
- No business logic
- Direct access discouraged for mutations

**Example Pattern:**
```sql
-- utils function (business logic)
CREATE FUNCTION utils.add_transaction(
    p_ledger_uuid text,
    p_account_uuid text,
    p_category_uuid text
) RETURNS int AS $$
-- All the complex logic here
$$;

-- api function (thin wrapper)
CREATE FUNCTION api.add_transaction(
    p_ledger_uuid uuid,
    p_account_uuid uuid,
    p_category_uuid uuid
) RETURNS uuid AS $$
BEGIN
    -- Just convert and delegate
    SELECT utils.add_transaction(
        p_ledger_uuid::text,
        p_account_uuid::text,
        p_category_uuid::text
    ) INTO v_id;
    -- Convert ID back to UUID and return
END;
$$;
```

### Go Conventions
- Follow standard Go formatting (gofmt)
- Use meaningful variable names
- Import aliases: `is_ "github.com/matryer/is"` for test assertions
- Error handling: Always check and handle errors appropriately
- Test structure: Use nested subtests with `t.Run()` for organization
- Use `context.Background()` for database operations in tests
- Store UUIDs as strings, internal IDs as int

### Testing
- Use `github.com/matryer/is` for test assertions
- Create dedicated test ledgers/accounts for each test suite
- Use `setupTestLedger()` helper for complex test scenarios
- Test both success and error cases
- Verify database state after operations