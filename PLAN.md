# PostgREST Removal Plan

## Overview
Remove all PostgREST configuration and dependencies from pgbudget while preserving all database functionality and business logic. This will transform the project from a web API backend to a pure database-only implementation.

## Goals
- ✅ Remove all PostgREST-specific configuration
- ✅ Eliminate `pgb_web_user` role and related grants
- ✅ Simplify user context handling
- ✅ Maintain all budgeting and accounting functionality
- ✅ Preserve test coverage and functionality
- ✅ Keep the clean three-schema architecture (`data`, `utils`, `api`)

## Milestones

### Milestone 1: Remove PostgREST Configuration Files
**Goal**: Eliminate PostgREST-specific migration files
**Estimated Time**: 5 minutes

#### Tasks:
1. **Delete PostgREST configuration migration**
   - File: `migrations/20250506162357_add_postgrest_api_config.sql`
   - Action: Complete file deletion
   - Reason: This entire migration is PostgREST-specific

### Milestone 2: Update Core Utility Functions
**Goal**: Replace JWT-based user context with database-native approach
**Estimated Time**: 10 minutes

#### Tasks:
1. **Update `utils.get_user()` function**
   - File: `migrations/20250506162103_add_global_utils.sql`
   - Change: Replace JWT claims parsing with `current_user`
   - Impact: All RLS policies and user context will use PostgreSQL's built-in user system

### Milestone 3: Remove Database Grants to Web User
**Goal**: Clean up all `pgb_web_user` role references
**Estimated Time**: 20 minutes

#### Tasks:
1. **Update ledgers table migration**
   - File: `migrations/20250506162508_add_ledgers_table.sql`
   - Remove: `grant all on data.ledgers to pgb_web_user;`
   - Remove: `grant usage, select on sequence data.ledgers_id_seq to pgb_web_user;`

2. **Update ledgers views migration**
   - File: `migrations/20250506162524_add_ledgers_views.sql`
   - Remove: `grant all on api.ledgers to pgb_web_user;`

3. **Update accounts table migration**
   - File: `migrations/20250506163248_add_accounts_table.sql`
   - Remove: `grant select, insert, update, delete on data.accounts to pgb_web_user;`
   - Remove: `grant usage, select on sequence data.accounts_id_seq to pgb_web_user;`

4. **Update accounts views migration**
   - File: `migrations/20250506163304_add_accounts_views.sql`
   - Remove: `grant select, insert, update, delete on api.accounts to pgb_web_user;`

5. **Update category views migration**
   - File: `migrations/20250506163325_add_category_views.sql`
   - Remove: `grant execute on function api.add_category(text, text) to pgb_web_user;`
   - Remove: `grant execute on function api.add_categories(text, text[]) to pgb_web_user;`
   - Remove corresponding revoke statements in Down section

6. **Update transactions table migration**
   - File: `migrations/20250506165219_add_transactions_table.sql`
   - Remove: `grant all on data.transactions to pgb_web_user;`
   - Remove: `grant usage, select on sequence data.transactions_id_seq to pgb_web_user;`

7. **Update transactions views migration**
   - File: `migrations/20250506165232_add_transactions_views.sql`
   - Remove: `grant select, insert, update, delete on api.transactions to pgb_web_user;`
   - Remove: `grant execute on function api.assign_to_category(...) to pgb_web_user;`

8. **Update balances table migration**
   - File: `migrations/20250506231405_add_balances_table.sql`
   - Remove: `grant select, insert, update, delete on data.balances to pgb_web_user;`
   - Remove: `grant usage, select on sequence data.balances_id_seq to pgb_web_user;`

9. **Update balances views migration**
   - File: `migrations/20250506231415_add_balances_views.sql`
   - Remove: `grant select on api.balances to pgb_web_user;`
   - Remove: `grant execute on function api.get_budget_status(text) to pgb_web_user;`
   - Remove: `grant execute on function api.get_account_transactions(text) to pgb_web_user;`
   - Remove corresponding revoke statement in Down section

### Milestone 4: Update Test Infrastructure
**Goal**: Remove JWT-based test setup and use database-native authentication
**Estimated Time**: 15 minutes

#### Tasks:
1. **Update test user context**
   - File: `main_test.go`
   - Remove: JWT claims setup section (lines ~45-70)
   - Replace: Use `pgcontainer.DefaultDbUser` for test user ID
   - Remove: JWT verification steps
   - Impact: Tests will use PostgreSQL's native user system

### Milestone 5: Validation and Testing
**Goal**: Ensure all functionality works after PostgREST removal
**Estimated Time**: 30 minutes

#### Tasks:
1. **Reset and rebuild database**
   - Command: `task migrate:drop`
   - Command: `task migrate:up`
   - Verify: No migration errors

2. **Run comprehensive tests**
   - Command: `go test -v`
   - Verify: All tests pass
   - Check: No PostgREST-related errors

3. **Manual verification**
   - Connect to database directly
   - Test core functions: ledger creation, transactions, budget status
   - Verify: All business logic intact

### Milestone 6: Documentation Updates
**Goal**: Update documentation to reflect database-only approach
**Estimated Time**: 20 minutes

#### Tasks:
1. **Update README.md**
   - Remove: PostgREST references
   - Remove: REST API examples
   - Remove: `pgb_web_user` role mentions
   - Update: Usage examples to show direct SQL
   - Add: Database connection instructions

2. **Update QUERIES.md** (if needed)
   - Review: Ensure examples work with new user context
   - Update: Any references to web user role

## Detailed Steps

### Step 1: File Deletion
```bash
rm migrations/20250506162357_add_postgrest_api_config.sql
```

### Step 2: Core Function Updates
Update `utils.get_user()` in `migrations/20250506162103_add_global_utils.sql`:
- Replace JWT claims parsing with `return current_user;`
- Simplify function logic
- Remove JWT-related error handling

### Step 3: Grant Removal Pattern
For each migration file containing grants:
1. Locate all `grant ... to pgb_web_user;` statements
2. Remove the entire line
3. Locate corresponding `revoke ... from pgb_web_user;` statements in Down sections
4. Remove those lines as well
5. Keep all other functionality intact

### Step 4: Test Updates
In `main_test.go`:
1. Remove JWT claims setup (lines with `set_config('request.jwt.claims', ...)`)
2. Replace `testUserID := "test_user_id_123"` with `testUserID := pgcontainer.DefaultDbUser`
3. Remove JWT verification steps
4. Keep all test logic and assertions

### Step 5: Verification Commands
```bash
# Reset database
task migrate:drop
task migrate:up

# Run tests
go test -v

# Manual database connection test
psql -h localhost -p <port> -U test -d test
```

## Success Criteria

### ✅ Technical Success
- [ ] All migrations run without errors
- [ ] All tests pass
- [ ] No references to `pgb_web_user` remain
- [ ] No references to JWT or PostgREST remain
- [ ] Database functions work with `current_user`

### ✅ Functional Success
- [ ] Can create ledgers and accounts
- [ ] Can record transactions (income, spending, transfers)
- [ ] Budget assignment works correctly
- [ ] Balance calculations are accurate
- [ ] Account transaction history functions properly
- [ ] All business logic preserved

### ✅ Code Quality Success
- [ ] Clean migration files with no PostgREST artifacts
- [ ] Simplified user context handling
- [ ] Maintained three-schema architecture
- [ ] Preserved comprehensive test coverage
- [ ] Updated documentation reflects new approach

## Risk Mitigation

### Low Risk Items
- **Grant removal**: Simple text deletion, no logic changes
- **File deletion**: PostgREST config is completely separate from business logic
- **Test updates**: Straightforward user context changes

### Medium Risk Items
- **`utils.get_user()` changes**: Core function used throughout system
  - Mitigation: Simple replacement, well-tested pattern
  - Rollback: Easy to revert if issues arise

### Rollback Plan
If issues arise:
1. Restore deleted PostgREST configuration file
2. Revert `utils.get_user()` function changes
3. Re-add grant statements
4. Restore JWT test setup
5. Run `task migrate:drop && task migrate:up`

## Post-Completion Benefits

### ✅ Simplified Architecture
- No web layer dependencies
- Direct database access
- Easier deployment (PostgreSQL only)
- Reduced complexity

### ✅ Maintained Functionality
- All budgeting logic preserved
- Same API schema structure
- Comprehensive test coverage
- Production-ready database foundation

### ✅ Enhanced Flexibility
- Use any PostgreSQL client
- Build custom applications on top
- Direct SQL access for power users
- No REST API constraints

## Timeline Summary
- **Total Estimated Time**: 1.5 - 2 hours
- **Critical Path**: Grant removal (longest task)
- **Dependencies**: Must complete in milestone order
- **Validation**: Comprehensive testing after each milestone

This plan ensures a systematic, low-risk removal of PostgREST while preserving all the excellent database functionality that makes pgbudget a robust budgeting system.
