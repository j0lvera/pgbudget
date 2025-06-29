package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/j0lvera/pgbudget/testutils/pgcontainer"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	is_ "github.com/matryer/is"
	"github.com/rs/zerolog"
)

var (
	testDSN string
	log     zerolog.Logger
)

func TestMain(m *testing.M) {
	// Setup logging
	log = zerolog.New(os.Stdout).With().Timestamp().Logger()

	// Create a context with timeout for setup
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Configure and start the PostgreSQL container
	cfg := pgcontainer.NewConfig()
	cfg.WithLogger(&log).WithMigrationsPath("migrations") // Path relative to project root (src)

	pgContainer := pgcontainer.NewPgContainer(cfg)
	output, err := pgContainer.Start(ctx)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to start PostgreSQL container")
	}

	// Store the DSN for tests to use
	testDSN = output.DSN()

	// Run the tests
	exitCode := m.Run()

	// Exit with the same code as the tests
	os.Exit(exitCode)
}

// Helper function to check if a slice contains a string
func contains(slice []string, str string) bool {
	for _, item := range slice {
		if item == str {
			return true
		}
	}
	return false
}

// setupTestLedger creates a new ledger with standard accounts and sample transactions
// using the public API layer (views and functions).
// Returns the ledger UUID, a map of account UUIDs by name, and a map of transaction UUIDs by name.
func setupTestLedger(
	ctx context.Context, conn *pgx.Conn, ledgerName string,
) (
	ledgerUUID string, accountUUIDs map[string]string,
	transactionUUIDs map[string]string, err error,
) { // Modified return types

	// Initialize maps
	accountUUIDs = make(map[string]string)
	transactionUUIDs = make(map[string]string)

	// 1. Create a new ledger via API view
	err = conn.QueryRow(
		ctx,
		"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
		ledgerName,
	).Scan(&ledgerUUID)
	if err != nil {
		err = fmt.Errorf("failed to create ledger via API view: %w", err)
		return // Return immediately on error
	}

	// 2. Create checking account via API view
	var checkingUUID string
	err = conn.QueryRow(
		ctx,
		`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, $3) RETURNING uuid`,
		ledgerUUID, "Checking", "asset",
	).Scan(&checkingUUID)
	if err != nil {
		err = fmt.Errorf(
			"failed to create checking account via view insert: %w", err,
		)
		return // Return immediately on error
	}
	accountUUIDs["Checking"] = checkingUUID

	// 3. Create groceries category via API function
	var groceriesUUID string
	// Since api.add_category returns SETOF, we need to select the specific column
	err = conn.QueryRow(
		ctx,
		"SELECT uuid FROM api.add_category($1, $2)", // Call new function
		ledgerUUID, "Groceries",
	).Scan(&groceriesUUID)
	if err != nil {
		err = fmt.Errorf("failed to create groceries category: %w", err)
		return // Return immediately on error
	}
	accountUUIDs["Groceries"] = groceriesUUID

	// 4. Find the Income category UUID (created automatically with ledger)
	var incomeUUID string
	err = conn.QueryRow(
		ctx,
		"SELECT utils.find_category($1, $2)", // Use utils function for lookup
		ledgerUUID, "Income",
	).Scan(&incomeUUID)
	if err != nil {
		err = fmt.Errorf("failed to find income category UUID: %w", err)
		return // Return immediately on error
	}
	if incomeUUID == "" { // Should not happen if ledger trigger works
		err = fmt.Errorf("income category UUID not found unexpectedly")
		return // Return immediately on error
	}
	accountUUIDs["Income"] = incomeUUID

	// 5. Add Income Transaction via api.transactions view (formerly simple_transactions)
	var incomeTxUUID string
	err = conn.QueryRow(
		ctx,
		`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`, // CHANGED to api.transactions
		ledgerUUID, "2023-01-01", "Salary deposit", "inflow", 100000,
		checkingUUID, incomeUUID,
	).Scan(&incomeTxUUID)
	if err != nil {
		err = fmt.Errorf(
			"failed to create income transaction via api.transactions view: %w", // CHANGED message
			err,
		)
		return // Return immediately on error
	}
	transactionUUIDs["Income"] = incomeTxUUID

	// 6. Assign Money to Groceries via API function
	var budgetTxUUID string
	// Since api.assign_to_category returns SETOF, we need to select the specific column
	err = conn.QueryRow(
		ctx,
		"SELECT uuid FROM api.assign_to_category($1, $2, $3, $4, $5)", // Call new function
		ledgerUUID, "2023-01-01", "Budget allocation to Groceries",
		30000,         // $300.00
		groceriesUUID, // Use category UUID
	).Scan(&budgetTxUUID)
	if err != nil {
		err = fmt.Errorf("failed to create budget transaction: %w", err)
		return // Return immediately on error
	}
	transactionUUIDs["Budget"] = budgetTxUUID

	// 7. Spend Money from Groceries via api.transactions view (formerly simple_transactions)
	var spendTxUUID string
	err = conn.QueryRow(
		ctx,
		`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`, // CHANGED to api.transactions
		ledgerUUID, "2023-01-02", "Grocery shopping", "outflow", 7500,
		checkingUUID, groceriesUUID,
	).Scan(&spendTxUUID)
	if err != nil {
		err = fmt.Errorf(
			"failed to create spending transaction via api.transactions view: %w", // CHANGED message
			err,
		)
		return // Return immediately on error
	}
	transactionUUIDs["Spend"] = spendTxUUID

	// Return UUIDs and nil error on success
	return ledgerUUID, accountUUIDs, transactionUUIDs, nil
}

// TestDatabase uses nested subtests to share context between tests
func TestDatabase(t *testing.T) {
	is := is_.New(t) // Main 'is' instance for top-level checks
	ctx := context.Background()

	// Connect to the database - this connection will be used by all subtests
	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err) // Should connect to database without error

	// Ensure cleanup after all subtests
	t.Cleanup(
		func() {
			conn.Close(ctx)
		},
	)

	// Session-based Authentication Context:
	// The application uses session variables to set user context for RLS policies.
	// utils.get_user() checks for 'app.current_user_id' session variable first,
	// then falls back to current_user for backward compatibility.
	// Tests can either set the session variable or rely on the current_user fallback.
	testUserID := pgcontainer.DefaultDbUser
	
	// Set the application user context for this test session
	// This simulates what the Go microservice would do for each authenticated request
	_, err = conn.Exec(ctx, "SELECT set_config('app.current_user_id', $1, true)", testUserID)
	is.NoErr(err) // Should be able to set user context
	
	// Verify the user context is set correctly
	var userFromSession string
	err = conn.QueryRow(ctx, `SELECT utils.get_user()`).Scan(&userFromSession)
	is.NoErr(err) // Should be able to get user from utils.get_user()
	is.Equal(userFromSession, testUserID) // User from session should match expected test user

	// Basic connection test
	t.Run(
		"Connection", func(t *testing.T) {
			is := is_.New(t) // is instance for this subtest

			// Verify connection works with a simple query
			var result int
			err = conn.QueryRow(ctx, "SELECT 1").Scan(&result)
			is.NoErr(err)       // Should execute query without error
			is.Equal(1, result) // Should return expected result
		},
	)

	// Create a ledger and store its ID and UUID for subsequent tests
	var ledgerID int      // Keep internal ID for verification steps if needed
	var ledgerUUID string // Primary identifier for API calls

	// --- Ledger Tests ---
	t.Run(
		"Ledgers", func(t *testing.T) {
			t.Run(
				"CreateLedger", func(t *testing.T) {
					is := is_.New(t) // is instance for this subtest
					ledgerName := "Test Budget"

					// Create a new ledger by inserting into the API view, returning the UUID
					err = conn.QueryRow(
						ctx,
						// Insert into the view, return the UUID exposed by the view
						"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
						ledgerName,
					).Scan(&ledgerUUID)       // Scan into ledgerUUID
					is.NoErr(err)             // Should create ledger without error
					is.True(ledgerUUID != "") // Should return a valid ledger UUID

					// Fetch the internal ID using the returned UUID (needed for direct data verification)
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.ledgers WHERE uuid = $1",
						ledgerUUID,
					).Scan(&ledgerID)
					is.NoErr(err)         // Should find the ledger by UUID
					is.True(ledgerID > 0) // Should have a valid internal ID

					// Verify the ledger was created correctly using the internal ID
					var name string
					// Query the base table directly for verification
					err = conn.QueryRow(
						ctx,
						"SELECT name FROM data.ledgers WHERE id = $1", // Use ledgerID here
						ledgerID,
					).Scan(&name)
					is.NoErr(err) // Should find the created ledger
					is.Equal(
						ledgerName, name,
					) // Ledger should have the correct name

					// Verify that the internal accounts were created using the internal ID
					var accountNames []string
					rows, err := conn.Query(
						ctx,
						"SELECT name FROM data.accounts WHERE ledger_id = $1 ORDER BY name", // Use ledgerID here
						ledgerID,
					)
					is.NoErr(err) // Should query accounts without error
					defer rows.Close()

					// Collect all account names
					for rows.Next() {
						var name string
						err = rows.Scan(&name)
						is.NoErr(err)
						accountNames = append(accountNames, name)
					}
					is.NoErr(rows.Err())

					log.Info().Interface(
						"accounts", accountNames,
					).Msg("Accounts")
					// According to README.md, we should have Income, Off-budget, and Unassigned accounts
					is.Equal(
						3, len(accountNames),
					) // Should have 3 default accounts
					is.True(contains(accountNames, "Income"))
					is.True(contains(accountNames, "Off-budget"))
					is.True(contains(accountNames, "Unassigned"))
				},
			)

			// Test updating ledger name via API view
			t.Run(
				"UpdateLedger", func(t *testing.T) {
					is := is_.New(t) // is instance for this subtest

					// Skip if ledger creation failed or did not run, so ledgerUUID is not available
					if ledgerUUID == "" {
						t.Skip("Skipping UpdateLedger because ledgerUUID is not available")
					}

					newLedgerName := "Updated Test Budget"

					// 1. Update the ledger name via the api.ledgers view
					// The view is updatable for simple cases like this.
					// PostgREST would translate a PATCH /ledgers?uuid=eq.{ledgerUUID} to a similar UPDATE.
					// We also want to return the updated name to verify the update statement itself worked as expected.
					var updatedNameFromView string
					err := conn.QueryRow(
						ctx,
						"UPDATE api.ledgers SET name = $1 WHERE uuid = $2 RETURNING name",
						newLedgerName,
						ledgerUUID,
					).Scan(&updatedNameFromView)
					is.NoErr(err) // Should update ledger name without error
					is.Equal(
						updatedNameFromView, newLedgerName,
					) // The name returned by RETURNING should be the new name

					// 2. Verify the name change by querying the api.ledgers view
					var nameFromView string
					err = conn.QueryRow(
						ctx,
						"SELECT name FROM api.ledgers WHERE uuid = $1",
						ledgerUUID,
					).Scan(&nameFromView)
					is.NoErr(err) // Should find the ledger in the view
					is.Equal(
						nameFromView, newLedgerName,
					) // Name in view should be the new name

					// 3. Verify the name change by querying the data.ledgers table directly
					var nameFromDataTable string
					err = conn.QueryRow(
						ctx, "SELECT name FROM data.ledgers WHERE uuid = $1",
						ledgerUUID,
					).Scan(&nameFromDataTable)
					is.NoErr(err) // Should find the ledger in the data table
					is.Equal(
						nameFromDataTable, newLedgerName,
					) // Name in data table should be the new name
				},
			)
			
		},
	)

	// --- Account Tests ---
	t.Run(
		"Accounts", func(t *testing.T) {
			// Create a dedicated ledger for account tests
			var accountsLedgerUUID string
			var accountsLedgerID int
			
			t.Run(
				"Setup_AccountsLedger", func(t *testing.T) {
					is := is_.New(t)
					
					// Create a new ledger specifically for account tests
					ledgerName := "Accounts Test Ledger"
					err := conn.QueryRow(
						ctx,
						"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
						ledgerName,
					).Scan(&accountsLedgerUUID)
					is.NoErr(err) // should create ledger without error
					
					// Get the internal ID for verification
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.ledgers WHERE uuid = $1",
						accountsLedgerUUID,
					).Scan(&accountsLedgerID)
					is.NoErr(err) // should find the ledger by UUID
					is.True(accountsLedgerID > 0) // should have a valid internal ID
				},
			)
			
			var accountUUID string // To be set by CreateAccount and used by UpdateAccount and DeleteAccount
			var accountID int      // Internal ID for data.accounts verification
			
			t.Run(
				"CreateAccount", func(t *testing.T) {
					is := is_.New(t)

					if accountsLedgerUUID == "" {
						t.Skip("Skipping CreateAccount because accountsLedgerUUID is not available")
					}

					accountName := "Test Savings Account"
					accountType := "asset"
					accountDescription := "Savings for a rainy day"
					// For JSONB, ensure it's a valid JSON string or null
					accountMetadataJSON := `{"goal": "emergency fund", "priority": 1}`
					var accountMetadataInput *string // Use pointer to string for metadata
					accountMetadataInput = &accountMetadataJSON

					var (
						retUUID        string
						retName        string
						retType        string
						retDescription pgtype.Text
						retMetadata    *[]byte // Matches existing test patterns for JSONB
						retUserData    string
						retLedgerUUID  string
					)

					// Insert into api.accounts view
					// Assumes an INSTEAD OF INSERT trigger handles this and returns relevant fields.
					// The trigger function utils.accounts_insert_single_fn populates NEW.uuid, NEW.name, etc.
					// NEW.ledger_uuid is from the input.
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.accounts (ledger_uuid, name, type, description, metadata)
			 VALUES ($1, $2, $3, $4, $5)
			 RETURNING uuid, name, type, description, metadata, user_data, ledger_uuid`,
						accountsLedgerUUID, accountName, accountType,
						accountDescription, accountMetadataInput,
					).Scan(
						&retUUID,
						&retName,
						&retType,
						&retDescription,
						&retMetadata,
						&retUserData,
						&retLedgerUUID,
					)
					is.NoErr(err) // Should create account without error

					// Assertions for returned values from the view insert
					is.True(retUUID != "") // Should return a valid account UUID
					accountUUID = retUUID  // Store for sub-test and further verification
					is.Equal(
						retName, accountName,
					) // Name should match
					is.Equal(
						retType, accountType,
					)                             // Type should match
					is.True(retDescription.Valid) // Description should be valid
					is.Equal(
						retDescription.String, accountDescription,
					)                           // Description should match
					is.True(retMetadata != nil) // Metadata should not be nil
					is.Equal(
						string(*retMetadata), accountMetadataJSON,
					) // Metadata should match
					is.Equal(
						retUserData, testUserID,
					) // UserData should match the test user
					is.Equal(
						retLedgerUUID, accountsLedgerUUID,
					) // LedgerUUID should match the input

					// Verify data in data.accounts table
					var (
						dbName         string
						dbType         string
						dbInternalType string
						dbDescription  pgtype.Text
						dbMetadata     []byte // Direct []byte for jsonb from table
						dbUserData     string
						dbLedgerID     int
					)
					err = conn.QueryRow(
						ctx,
						`SELECT id, name, type, internal_type, description, metadata, user_data, ledger_id
			 FROM data.accounts WHERE uuid = $1`,
						accountUUID,
					).Scan(
						&accountID, // Store internal ID
						&dbName,
						&dbType,
						&dbInternalType,
						&dbDescription,
						&dbMetadata,
						&dbUserData,
						&dbLedgerID,
					)
					is.NoErr(err) // Should find the account in data.accounts

					is.True(accountID > 0) // Should have a valid internal ID
					is.Equal(
						dbName, accountName,
					) // Name in DB should match
					is.Equal(
						dbType, accountType,
					) // Type in DB should match
					is.Equal(
						dbInternalType, "asset_like",
					)                            // Internal type should be correctly set by trigger
					is.True(dbDescription.Valid) // DB Description should be valid
					is.Equal(
						dbDescription.String, accountDescription,
					) // DB Description should match
					is.Equal(
						string(dbMetadata), accountMetadataJSON,
					) // DB Metadata should match
					is.Equal(
						dbUserData, testUserID,
					) // DB UserData should match
					is.Equal(
						dbLedgerID, accountsLedgerID,
					) // DB LedgerID should match the parent ledger's internal ID
				},
			)

			// Subtest for updating the account
			t.Run(
				"UpdateAccount", func(t *testing.T) {
					is := is_.New(t)

					if accountUUID == "" {
						t.Skip("Skipping UpdateAccount because accountUUID is not available from CreateAccount")
					}

					newAccountName := "Updated Test Savings Account"

					// Update the account name via api.accounts view
					// Assumes an INSTEAD OF UPDATE trigger handles this if the view is complex.
					// If simple, PostgreSQL might handle it directly.
					var updatedNameFromView string
					err := conn.QueryRow(
						ctx,
						"UPDATE api.accounts SET name = $1 WHERE uuid = $2 RETURNING name",
						newAccountName, accountUUID,
					).Scan(&updatedNameFromView)
					is.NoErr(err) // Should update account name without error
					is.Equal(
						updatedNameFromView, newAccountName,
					) // Name returned by RETURNING should be the new name

					// Verify name change by querying api.accounts view
					var nameFromView string
					err = conn.QueryRow(
						ctx, "SELECT name FROM api.accounts WHERE uuid = $1",
						accountUUID,
					).Scan(&nameFromView)
					is.NoErr(err) // Should find the account in the view
					is.Equal(
						nameFromView, newAccountName,
					) // Name in view should be the new name

					// Verify name change by querying data.accounts table
					var nameFromDataTable string
					err = conn.QueryRow(
						ctx, "SELECT name FROM data.accounts WHERE uuid = $1",
						accountUUID,
					).Scan(&nameFromDataTable)
					is.NoErr(err) // Should find the account in the data table
					is.Equal(
						nameFromDataTable, newAccountName,
					) // Name in data table should be the new name
				},
			)
			
			// New subtest for deleting a regular account
			t.Run(
				"DeleteRegularAccount", func(t *testing.T) {
					is := is_.New(t)
					
					if accountsLedgerUUID == "" {
						t.Skip("Skipping DeleteRegularAccount because accountsLedgerUUID is not available")
					}
					
					// Create another account specifically for deletion
					var deleteAccountUUID string
					accountName := "Account To Delete"
					accountType := "asset"
					
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.accounts (ledger_uuid, name, type) 
						 VALUES ($1, $2, $3) RETURNING uuid`,
						accountsLedgerUUID, accountName, accountType,
					).Scan(&deleteAccountUUID)
					is.NoErr(err) // Should create account without error
					is.True(deleteAccountUUID != "") // Should return a valid UUID
					
					// Verify account exists before deletion
					var exists bool
					err = conn.QueryRow(
						ctx,
						"SELECT EXISTS(SELECT 1 FROM api.accounts WHERE uuid = $1)",
						deleteAccountUUID,
					).Scan(&exists)
					is.NoErr(err)
					is.True(exists) // Account should exist before deletion
					
					// Delete the account via api.accounts view
					_, err = conn.Exec(
						ctx,
						"DELETE FROM api.accounts WHERE uuid = $1",
						deleteAccountUUID,
					)
					is.NoErr(err) // Should delete account without error
					
					// Verify account no longer exists in api.accounts view
					err = conn.QueryRow(
						ctx,
						"SELECT EXISTS(SELECT 1 FROM api.accounts WHERE uuid = $1)",
						deleteAccountUUID,
					).Scan(&exists)
					is.NoErr(err)
					is.True(!exists) // Account should no longer exist
					
					// Verify account no longer exists in data.accounts table
					err = conn.QueryRow(
						ctx,
						"SELECT EXISTS(SELECT 1 FROM data.accounts WHERE uuid = $1)",
						deleteAccountUUID,
					).Scan(&exists)
					is.NoErr(err)
					is.True(!exists) // Account should no longer exist in data table
				},
			)
			
			// Test attempting to delete a special account (should fail)
			t.Run(
				"DeleteSpecialAccount", func(t *testing.T) {
					is := is_.New(t)
					
					if accountsLedgerUUID == "" {
						t.Skip("Skipping DeleteSpecialAccount because accountsLedgerUUID is not available")
					}
					
					// Find the Income account UUID (created automatically with ledger)
					var incomeAccountUUID string
					err := conn.QueryRow(
						ctx,
						"SELECT utils.find_category($1, $2)",
						accountsLedgerUUID, "Income",
					).Scan(&incomeAccountUUID)
					is.NoErr(err) // Should find Income category
					is.True(incomeAccountUUID != "") // Should have a valid UUID
					
					// Attempt to delete the Income account (should fail)
					_, err = conn.Exec(
						ctx,
						"DELETE FROM api.accounts WHERE uuid = $1",
						incomeAccountUUID,
					)
					is.True(err != nil) // Should return an error
					
					// Check for specific error message
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr)) // Error should be a PgError
					is.True(strings.Contains(pgErr.Message, "Cannot delete special account")) // Check error message
					
					// Verify Income account still exists
					var exists bool
					err = conn.QueryRow(
						ctx,
						"SELECT EXISTS(SELECT 1 FROM api.accounts WHERE uuid = $1)",
						incomeAccountUUID,
					).Scan(&exists)
					is.NoErr(err)
					is.True(exists) // Income account should still exist
				},
			)
		},
	)

	// --- Category Tests ---
	t.Run(
		"Categories", func(t *testing.T) {
			// Create a dedicated ledger for category tests
			var categoriesLedgerUUID string
			var categoriesLedgerID int
			
			t.Run(
				"Setup_CategoriesLedger", func(t *testing.T) {
					is := is_.New(t)
					
					// Create a new ledger specifically for category tests
					ledgerName := "Categories Test Ledger"
					err := conn.QueryRow(
						ctx,
						"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
						ledgerName,
					).Scan(&categoriesLedgerUUID)
					is.NoErr(err) // should create ledger without error
					
					// Get the internal ID for verification
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.ledgers WHERE uuid = $1",
						categoriesLedgerUUID,
					).Scan(&categoriesLedgerID)
					is.NoErr(err) // should find the ledger by UUID
					is.True(categoriesLedgerID > 0) // should have a valid internal ID
				},
			)
			
			// This is the subtest for creating a category
			t.Run(
				"CreateCategory", func(t *testing.T) {
					// Skip if ledger creation failed
					if categoriesLedgerUUID == "" {
						t.Skip("Skipping CreateCategory tests because categories ledger creation failed or did not run")
					}

					//is := is_.New(t)
					categoryName := "Groceries"
					var categoryUUID string

					// 1. Call api.add_category (Success Case)
					t.Run(
						"Success", func(t *testing.T) {
							is := is_.New(t) // is instance for this subtest
							var (
								retUUID        string
								retName        string
								retType        string
								retDescription pgtype.Text
								retMetadata    *[]byte // Use pointer to byte slice for jsonb
								retUserData    string
								retLedgerUUID  string
							)

							// Call the function and scan all returned fields
							// Since it returns SETOF, QueryRow works if exactly one row is expected
							err := conn.QueryRow(
								ctx, "SELECT * FROM api.add_category($1, $2)",
								categoriesLedgerUUID, categoryName,
							).Scan(
								&retUUID,
								&retName,
								&retType,
								&retDescription,
								&retMetadata, // Pass address of pointer
								&retUserData,
								&retLedgerUUID,
							)
							is.NoErr(err) // Should execute function without error

							// Assert Return Values
							is.True(retUUID != "") // Should return a non-empty UUID
							is.Equal(
								retName, categoryName,
							) // Returned name should match input
							is.Equal(
								retType, "equity",
							) // Returned type should be 'equity'
							is.Equal(
								retLedgerUUID, categoriesLedgerUUID,
							) // Returned ledger UUID should match input
							is.Equal(
								retUserData, testUserID,
							)                              // Returned user_data should match simulated user
							is.True(!retDescription.Valid) // Description should be null initially
							is.True(retMetadata == nil)    // Metadata should be null initially (check if pointer is nil)

							categoryUUID = retUUID // Store for later verification and tests
						},
					)

					// 2. Verify Database State
					t.Run(
						"VerifyDatabase", func(t *testing.T) {
							is := is_.New(t) // is instance for this subtest
							// Skip if the previous step failed to get a UUID
							if categoryUUID == "" {
								t.Skip("Skipping VerifyDatabase because category UUID was not captured")
							}

							var (
								dbID           int
								dbLedgerID     int
								dbName         string
								dbType         string
								dbInternalType string
								dbUserData     string
								dbDescription  pgtype.Text
								dbMetadata     *[]byte // Use pointer to byte slice for jsonb
							)

							// Query the data.accounts table directly
							err := conn.QueryRow(
								ctx,
								`SELECT id, ledger_id, name, type, internal_type, user_data, description, metadata
                 FROM data.accounts WHERE uuid = $1`, categoryUUID,
							).Scan(
								&dbID,
								&dbLedgerID,
								&dbName,
								&dbType,
								&dbInternalType,
								&dbUserData,
								&dbDescription,
								&dbMetadata, // Pass address of pointer
							)
							is.NoErr(err) // Should find the account in the database

							// Assert Database Values
							is.Equal(
								dbLedgerID, categoriesLedgerID,
							) // Ledger ID should match the one created earlier
							is.Equal(
								dbName, categoryName,
							) // Name should match
							is.Equal(
								dbType, "equity",
							) // Type should be 'equity'
							is.Equal(
								dbInternalType, "liability_like",
							) // Internal type should be 'liability_like'
							is.Equal(
								dbUserData, testUserID,
							)                             // User data should match
							is.True(!dbDescription.Valid) // Description should be null
							is.True(dbMetadata == nil)    // Metadata should be null (check if pointer is nil)
						},
					)

					// 3. Test Error Case: Duplicate Name
					t.Run(
						"DuplicateNameError", func(t *testing.T) {
							is := is_.New(t) // is instance for this subtest
							// Skip if the category wasn't created successfully
							if categoryUUID == "" {
								t.Skip("Skipping DuplicateNameError because category UUID was not captured")
							}

							// Call add_category again with the same name
							_, err := conn.Exec(
								ctx, "SELECT api.add_category($1, $2)",
								categoriesLedgerUUID,
								categoryName,
							)
							is.True(err != nil) // Should return an error

							// Check for PostgreSQL unique violation error (code 23505)
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							is.Equal(
								pgErr.Code, "23505",
							) // Error code should be unique_violation
						},
					)

					// 4. Test Error Case: Invalid Ledger
					t.Run(
						"InvalidLedgerError", func(t *testing.T) {
							is := is_.New(t)                                            // is instance for this subtest
							invalidLedgerUUID := "00000000-0000-0000-0000-000000000000" // Or any non-existent UUID

							_, err := conn.Exec(
								ctx, "SELECT api.add_category($1, $2)",
								invalidLedgerUUID, "Another Category",
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.add_category
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// Check the Message field for the specific exception text raised by the function
							is.True(
								strings.Contains(
									pgErr.Message, "not found for current user",
								),
							)
						},
					)

					// 5. Test Error Case: Empty Name
					t.Run(
						"EmptyNameError", func(t *testing.T) {
							is := is_.New(t) // is instance for this subtest

							_, err := conn.Exec(
								ctx, "SELECT api.add_category($1, $2)",
								categoriesLedgerUUID, "",
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.add_category
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// Check the Message field for the specific exception text raised by the function
							is.True(
								strings.Contains(
									pgErr.Message,
									"Category name cannot be empty",
								),
							)
						},
					)
				},
			) // End of t.Run("CreateCategory", ...)
		},
	) // End of t.Run("Categories", ...)

	// --- Transaction Tests ---
	t.Run(
		"Transactions", func(t *testing.T) {
			// Create a dedicated ledger for transaction tests
			var transactionLedgerUUID string
			var transactionLedgerID int
			
			t.Run(
				"Setup_TransactionLedger", func(t *testing.T) {
					is := is_.New(t)
					
					// Create a new ledger specifically for transaction tests
					ledgerName := "Transactions Test Ledger"
					err := conn.QueryRow(
						ctx,
						"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
						ledgerName,
					).Scan(&transactionLedgerUUID)
					is.NoErr(err) // should create ledger without error
					
					// Get the internal ID for verification
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.ledgers WHERE uuid = $1",
						transactionLedgerUUID,
					).Scan(&transactionLedgerID)
					is.NoErr(err) // should find the ledger by UUID
					is.True(transactionLedgerID > 0) // should have a valid internal ID
				},
			)
			
			// These UUIDs will be populated by sub-setup tests within "CreateTransaction"
			var mainAccountUUID string       // e.g., a checking account
			var expenseCategoryUUID string   // e.g., a "Shopping" category

			// Internal IDs for verification
			var mainAccountID int
			var expenseCategoryID int

			t.Run(
				"CreateTransaction", func(t *testing.T) {
					// Use the dedicated ledger UUID instead of the one from the outer scope
					if transactionLedgerUUID == "" {
						t.Skip("Skipping CreateTransaction tests because transaction ledger UUID is not available")
					}

					// Setup: Create a specific account and category for this transaction test
					t.Run(
						"Setup_TransactionPrerequisites", func(t *testing.T) {
							is := is_.New(t)

							// 1. Create a main account (e.g., Checking) for transactions
							accountName := "Tx-Checking Account"
							accountType := "asset"
							err := conn.QueryRow(
								ctx,
								`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, $3) RETURNING uuid`,
								transactionLedgerUUID, accountName, accountType,
							).Scan(&mainAccountUUID)
							is.NoErr(err)
							is.True(mainAccountUUID != "")

							// Get internal ID for verification later
							err = conn.QueryRow(
								ctx,
								"SELECT id FROM data.accounts WHERE uuid = $1",
								mainAccountUUID,
							).Scan(&mainAccountID)
							is.NoErr(err)
							is.True(mainAccountID > 0)

							// 2. Create an expense category (e.g., Shopping) for transactions
							categoryName := "Tx-Shopping Category"
							err = conn.QueryRow(
								ctx,
								"SELECT uuid FROM api.add_category($1, $2)",
								transactionLedgerUUID, categoryName,
							).Scan(&expenseCategoryUUID)
							is.NoErr(err)
							is.True(expenseCategoryUUID != "")

							// Get internal ID for verification later
							err = conn.QueryRow(
								ctx,
								"SELECT id FROM data.accounts WHERE uuid = $1",
								expenseCategoryUUID,
							).Scan(&expenseCategoryID)
							is.NoErr(err)
							is.True(expenseCategoryID > 0)
						},
					)

					// Skip further tests if setup failed
					if mainAccountUUID == "" || expenseCategoryUUID == "" {
						t.Skip("Skipping CreateTransaction sub-tests because prerequisite account/category creation failed")
						return // Important to return to prevent further execution in this subtest
					}

					var createdTransactionUUID string // To store the UUID of the created transaction

					// Subtest for successful transaction creation (Outflow)
					t.Run(
						"Success_Outflow", func(t *testing.T) {
							is := is_.New(t)
							txDate := time.Now()
							txDescription := "New Gadget Purchase"
							txAmount := int64(12500) // $125.00
							txType := "outflow"      // Spending from an asset account

							var (
								retUUID         string
								retDate         pgtype.Timestamptz
								retDescription  string
								retAmount       int64
								retLedgerUUID   string
								retAccountUUID  string // This should be NEW.account_uuid from the trigger
								retCategoryUUID string // This should be NEW.category_uuid from the trigger
								retType         string // This should be NEW.type from the trigger
								retMetadata     *[]byte
							)

							// Insert into api.transactions view
							// The trigger utils.simple_transactions_insert_fn handles the logic
							// and populates the NEW record which is returned.
							err := conn.QueryRow(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date, metadata)
					 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
					 RETURNING uuid, date, description, amount, ledger_uuid, account_uuid, category_uuid, type, metadata`,
								transactionLedgerUUID, mainAccountUUID,
								expenseCategoryUUID, txType,
								txAmount, txDescription, txDate,
								nil, // Assuming metadata is null for now
							).Scan(
								&retUUID,
								&retDate,
								&retDescription,
								&retAmount,
								&retLedgerUUID,
								&retAccountUUID,
								&retCategoryUUID,
								&retType,
								&retMetadata,
							)
							is.NoErr(err) // Should create transaction without error

							// Assertions for returned values
							is.True(retUUID != "")           // Should return a valid transaction UUID
							createdTransactionUUID = retUUID // Store for verification
							is.Equal(retDescription, txDescription)
							is.Equal(retAmount, txAmount)
							is.True(retDate.Time.Unix()-txDate.Unix() < 2) // Check if times are very close
							is.Equal(retLedgerUUID, transactionLedgerUUID)
							is.Equal(
								retAccountUUID, mainAccountUUID,
							) // Should match the input account_uuid
							is.Equal(
								retCategoryUUID, expenseCategoryUUID,
							) // Should match the input category_uuid
							is.Equal(
								retType, txType,
							)                                                  // Should match the input type
							is.True(retMetadata == nil || *retMetadata == nil) // Metadata should be null or empty JSON
						},
					)

					// Subtest for verifying database state after outflow
					t.Run(
						"VerifyDatabase_Outflow", func(t *testing.T) {
							is := is_.New(t)
							if createdTransactionUUID == "" {
								t.Skip("Skipping VerifyDatabase_Outflow because transaction UUID was not captured")
							}

							var (
								dbLedgerID        int
								dbDescription     string
								dbDate            pgtype.Timestamptz
								dbAmount          int64
								dbDebitAccountID  int
								dbCreditAccountID int
								dbUserData        string
							)

							err := conn.QueryRow(
								ctx,
								`SELECT ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data
					 FROM data.transactions WHERE uuid = $1`,
								createdTransactionUUID,
							).Scan(
								&dbLedgerID,
								&dbDescription,
								&dbDate,
								&dbAmount,
								&dbDebitAccountID,
								&dbCreditAccountID,
								&dbUserData,
							)
							is.NoErr(err) // Should find the transaction in data.transactions

							// Assertions for database values
							is.Equal(
								dbLedgerID, transactionLedgerID,
							) // Internal ledger ID should match
							is.Equal(dbDescription, "New Gadget Purchase")
							is.Equal(dbAmount, int64(12500))
							is.Equal(
								dbUserData, testUserID,
							) // User data should match the simulated user

							// For an outflow from an asset account ("Tx-Checking Account"):
							// Debit: Category ("Tx-Shopping Category")
							// Credit: Account ("Tx-Checking Account")
							is.Equal(
								dbDebitAccountID, expenseCategoryID,
							) // Debit should be the category's internal ID
							is.Equal(
								dbCreditAccountID, mainAccountID,
							) // Credit should be the main account's internal ID
						},
					)

					var createdInflowTransactionUUID string // To store the UUID of the created inflow transaction

					// Subtest for successful transaction creation (Inflow)
					t.Run(
						"Success_Inflow", func(t *testing.T) {
							is := is_.New(t)
							txDate := time.Now().Add(time.Hour) // Slightly different time for uniqueness
							txDescription := "Client Payment Received"
							txAmount := int64(50000) // $500.00
							txType := "inflow"       // Receiving into an asset account

							var (
								retUUID         string
								retDate         pgtype.Timestamptz
								retDescription  string
								retAmount       int64
								retLedgerUUID   string
								retAccountUUID  string
								retCategoryUUID string
								retType         string
								retMetadata     *[]byte
							)

							err := conn.QueryRow(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date, metadata)
					 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
					 RETURNING uuid, date, description, amount, ledger_uuid, account_uuid, category_uuid, type, metadata`,
								transactionLedgerUUID, mainAccountUUID,
								expenseCategoryUUID,
								txType, // Using expenseCategoryUUID as the source category for inflow
								txAmount, txDescription, txDate, nil,
							).Scan(
								&retUUID,
								&retDate,
								&retDescription,
								&retAmount,
								&retLedgerUUID,
								&retAccountUUID,
								&retCategoryUUID,
								&retType,
								&retMetadata,
							)
							is.NoErr(err) // Should create transaction without error

							// Assertions for returned values
							is.True(retUUID != "")                 // Should return a valid transaction UUID
							createdInflowTransactionUUID = retUUID // Store for verification
							is.Equal(retDescription, txDescription)
							is.Equal(retAmount, txAmount)
							is.True(retDate.Time.Unix()-txDate.Unix() < 2) // Check if times are very close
							is.Equal(retLedgerUUID, transactionLedgerUUID)
							is.Equal(
								retAccountUUID, mainAccountUUID,
							) // Should match the input account_uuid
							is.Equal(
								retCategoryUUID, expenseCategoryUUID,
							) // Should match the input category_uuid
							is.Equal(
								retType, txType,
							) // Should match the input type
							is.True(retMetadata == nil || *retMetadata == nil)
						},
					)

					// Subtest for verifying database state after inflow
					t.Run(
						"VerifyDatabase_Inflow", func(t *testing.T) {
							is := is_.New(t)
							if createdInflowTransactionUUID == "" {
								t.Skip("Skipping VerifyDatabase_Inflow because inflow transaction UUID was not captured")
							}

							var (
								dbLedgerID        int
								dbDescription     string
								dbDate            pgtype.Timestamptz
								dbAmount          int64
								dbDebitAccountID  int
								dbCreditAccountID int
								dbUserData        string
							)

							err := conn.QueryRow(
								ctx,
								`SELECT ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data
					 FROM data.transactions WHERE uuid = $1`,
								createdInflowTransactionUUID,
							).Scan(
								&dbLedgerID,
								&dbDescription,
								&dbDate,
								&dbAmount,
								&dbDebitAccountID,
								&dbCreditAccountID,
								&dbUserData,
							)
							is.NoErr(err) // Should find the transaction in data.transactions

							// Assertions for database values
							is.Equal(
								dbLedgerID, transactionLedgerID,
							) // Internal ledger ID should match
							is.Equal(dbDescription, "Client Payment Received")
							is.Equal(dbAmount, int64(50000))
							is.Equal(
								dbUserData, testUserID,
							) // User data should match the simulated user

							// For an inflow to an asset account ("Tx-Checking Account"):
							// Debit: Account ("Tx-Checking Account")
							// Credit: Category ("Tx-Shopping Category" in this example)
							is.Equal(
								dbDebitAccountID, mainAccountID,
							) // Debit should be the main account's internal ID
							is.Equal(
								dbCreditAccountID, expenseCategoryID,
							) // Credit should be the category's internal ID
						},
					)

					// Subtest for error case: Invalid Ledger
					t.Run(
						"Error_InvalidLedger", func(t *testing.T) {
							is := is_.New(t)
							invalidLedgerUUID := "00000000-0000-0000-0000-000000000000" // A non-existent UUID
							txDate := time.Now()
							txDescription := "Transaction with invalid ledger"
							txAmount := int64(1000) // $10.00
							txType := "outflow"

							// Attempt to insert with an invalid ledger_uuid
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								invalidLedgerUUID,   // Using the invalid ledger UUID
								mainAccountUUID,     // Valid account UUID (though it won't be found under invalid ledger)
								expenseCategoryUUID, // Valid category UUID (same as above)
								txType,
								txAmount,
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Ledger with UUID % not found for current user'
							is.True(
								strings.Contains(
									strings.ToLower(pgErr.Message), "ledger with uuid",
								),
							)
							is.True(
								strings.Contains(
									pgErr.Message, "not found for current user",
								),
							)
						},
					) // End of t.Run("Error_InvalidLedger", ...)

					// Subtest for error case: Invalid Account
					t.Run(
						"Error_InvalidAccount", func(t *testing.T) {
							is := is_.New(t)
							invalidAccountUUID := "11111111-1111-1111-1111-111111111111" // A non-existent UUID
							txDate := time.Now()
							txDescription := "Transaction with invalid account"
							txAmount := int64(2000) // $20.00
							txType := "outflow"

							// Attempt to insert with an invalid account_uuid
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								transactionLedgerUUID, // Valid ledger UUID
								invalidAccountUUID,    // Using the invalid account UUID
								expenseCategoryUUID,   // Valid category UUID
								txType,
								txAmount,
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Account with UUID % not found in ledger %'
							is.True(
								strings.Contains(
									pgErr.Message, "Account with UUID",
								),
							)
							is.True(
								strings.Contains(
									pgErr.Message, "not found in ledger",
								),
							)
						},
					) // End of t.Run("Error_InvalidAccount", ...)

					// Subtest for error case: Invalid Category
					t.Run(
						"Error_InvalidCategory", func(t *testing.T) {
							is := is_.New(t)
							invalidCategoryUUID := "22222222-2222-2222-2222-222222222222" // A non-existent UUID
							txDate := time.Now()
							txDescription := "Transaction with invalid category"
							txAmount := int64(3000) // $30.00
							txType := "outflow"

							// Attempt to insert with an invalid category_uuid
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								transactionLedgerUUID, // Valid ledger UUID
								mainAccountUUID,       // Valid account UUID
								invalidCategoryUUID,   // Using the invalid category UUID
								txType,
								txAmount,
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Category with UUID % not found in ledger %'
							is.True(
								strings.Contains(
									pgErr.Message, "Category with UUID",
								),
							)
							is.True(
								strings.Contains(
									pgErr.Message, "not found in ledger",
								),
							)
						},
					) // End of t.Run("Error_InvalidCategory", ...)

					// Subtest for error case: Invalid Transaction Type
					t.Run(
						"Error_InvalidType", func(t *testing.T) {
							is := is_.New(t)
							invalidTxType := "sideways" // An invalid transaction type
							txDate := time.Now()
							txDescription := "Transaction with invalid type"
							txAmount := int64(4000) // $40.00

							// Attempt to insert with an invalid type
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								transactionLedgerUUID, // Valid ledger UUID
								mainAccountUUID,       // Valid account UUID
								expenseCategoryUUID,   // Valid category UUID
								invalidTxType,         // Using the invalid transaction type
								txAmount,
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Invalid transaction type: %. Must be either "inflow" or "outflow"'
							is.True(
								strings.Contains(
									pgErr.Message, "Invalid transaction type",
								),
							)
							is.True(
								strings.Contains(
									pgErr.Message,
									`Must be either "inflow" or "outflow"`,
								),
							)
						},
					) // End of t.Run("Error_InvalidType", ...)

					// Subtest for error case: Zero Amount
					t.Run(
						"Error_ZeroAmount", func(t *testing.T) {
							is := is_.New(t)
							txDate := time.Now()
							txDescription := "Transaction with zero amount"
							txAmount := int64(0) // Zero amount
							txType := "outflow"

							// Attempt to insert with zero amount
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								transactionLedgerUUID, // Valid ledger UUID
								mainAccountUUID,       // Valid account UUID
								expenseCategoryUUID,   // Valid category UUID
								txType,
								txAmount, // Using zero amount
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Transaction amount must be positive: %'
							is.True(
								strings.Contains(
									pgErr.Message,
									"Transaction amount must be positive",
								),
							)
						},
					) // End of t.Run("Error_ZeroAmount", ...)

					// Subtest for error case: Negative Amount
					t.Run(
						"Error_NegativeAmount", func(t *testing.T) {
							is := is_.New(t)
							txDate := time.Now()
							txDescription := "Transaction with negative amount"
							txAmount := int64(-5000) // Negative amount
							txType := "outflow"

							// Attempt to insert with negative amount
							_, err := conn.Exec(
								ctx,
								`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
					 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
								transactionLedgerUUID, // Valid ledger UUID
								mainAccountUUID,       // Valid account UUID
								expenseCategoryUUID,   // Valid category UUID
								txType,
								txAmount, // Using negative amount
								txDescription,
								txDate,
							)
							is.True(err != nil) // Should return an error

							// Check for the specific error message from utils.simple_transactions_insert_fn
							var pgErr *pgconn.PgError
							is.True(
								errors.As(
									err, &pgErr,
								),
							) // Error should be a PgError
							// The expected message from utils.simple_transactions_insert_fn is 'Transaction amount must be positive: %'
							is.True(
								strings.Contains(
									pgErr.Message,
									"Transaction amount must be positive",
								),
							)
						},
					)

					// TODO: Add more subtests for "CreateTransaction"
					// (Consider if there are other specific error paths in simple_transactions_insert_fn)
				},
			) // End of t.Run("CreateTransaction", ...)
		},
	) // End of t.Run("Transactions", ...)

	// Test api.assign_to_category function
	t.Run(
		"AssignToCategory", func(t *testing.T) {
			// Create a ledger specifically for this test if one isn't available
			is := is_.New(t)

			// Create a new ledger using the api.ledgers view
			ledgerName := "AssignToCategory Test Ledger"
			err := conn.QueryRow(
				ctx,
				"insert into api.ledgers (name) values ($1) returning uuid",
				ledgerName,
			).Scan(&ledgerUUID)
			is.NoErr(err) // should create ledger without error

			// Create a groceries category for this test
			var groceriesCategoryUUID string
			t.Run(
				"Setup_CreateGroceries", func(t *testing.T) {
					is := is_.New(t)
					if ledgerUUID == "" {
						t.Skip("Skipping because ledger UUID is not available")
					}

					// Create a new Groceries category using api.add_category
					err := conn.QueryRow(
						ctx,
						"select uuid from api.add_category($1, $2)",
						ledgerUUID, "Groceries",
					).Scan(&groceriesCategoryUUID)
					is.NoErr(err) // should create category without error
					is.True(groceriesCategoryUUID != "")
				},
			)

			// Skip subsequent tests if prerequisites failed
			if ledgerUUID == "" || groceriesCategoryUUID == "" {
				t.Skip("Skipping AssignToCategory tests because ledger or groceries category UUID is not available")
			}

			// Find Income category UUID (created automatically with ledger)
			var incomeCategoryUUID string
			err = conn.QueryRow(
				ctx,
				"select utils.find_category($1, $2)",
				ledgerUUID, "Income",
			).Scan(&incomeCategoryUUID)
			is.NoErr(err) // should find Income category
			is.True(incomeCategoryUUID != "")

			// --- Helper function to get balance ---
			getBalance := func(accountUUID string) (int64, error) {
				var balance int64
				var accountID int
				var ledgerID int
				
				// Get account ID and ledger ID
				err := conn.QueryRow(
					ctx, 
					"SELECT id, ledger_id FROM data.accounts WHERE uuid = $1",
					accountUUID,
				).Scan(&accountID, &ledgerID)
				if err != nil {
					return 0, fmt.Errorf("failed to get account info for UUID %s: %w", accountUUID, err)
				}
				
				// Use the on-demand balance calculation function
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					ledgerID, accountID,
				).Scan(&balance)
				if err != nil {
					return 0, fmt.Errorf("failed to get balance for account ID %d: %w", accountID, err)
				}
				return balance, nil
			}
			// --- End Helper ---

			var initialIncomeBalance, initialGroceriesBalance int64
			initialIncomeBalance, err = getBalance(incomeCategoryUUID)
			is.NoErr(err)
			initialGroceriesBalance, err = getBalance(groceriesCategoryUUID)
			is.NoErr(err)

			assignAmount := int64(5000) // $50.00
			assignDesc := "Assign $50 to Groceries"
			assignDate := time.Now()
			var transactionUUID string // Store UUID for verification

			// 1. Call api.assign_to_category (Success Case)
			t.Run(
				"Success", func(t *testing.T) {
					is := is_.New(t)

					var (
						retUUID         string
						retDescription  string
						retAmount       int64
						retDate         time.Time
						retMetadata     *[]byte
						retLedgerUUID   string
						retType         sql.NullString
						retAccountUUID  string
						retCategoryUUID string
					)

					// Since it returns SETOF, QueryRow works if exactly one row is expected
					err := conn.QueryRow(
						ctx,
						"SELECT uuid, description, amount, date, metadata, ledger_uuid, type, account_uuid, category_uuid FROM api.assign_to_category($1, $2, $3, $4, $5)",
						ledgerUUID, assignDate, assignDesc, assignAmount,
						groceriesCategoryUUID,
					).Scan(
						&retUUID,
						&retDescription,
						&retAmount,
						&retDate,
						&retMetadata,
						&retLedgerUUID,
						&retType,
						&retAccountUUID,
						&retCategoryUUID,
					)

					is.NoErr(err) // Should execute function without error

					// Assert Return Values
					is.True(retUUID != "") // Should return a non-empty UUID
					is.Equal(
						retDescription, assignDesc,
					)                                 // Description should match
					is.Equal(retAmount, assignAmount) // Amount should match
					// is.Equal(retDate, assignDate) // Be careful comparing time directly due to potential precision differences
					is.True(retDate.Unix()-assignDate.Unix() < 2) // Check if times are very close (within a second)
					is.Equal(
						retLedgerUUID, ledgerUUID,
					)                       // Ledger UUID should match
					is.True(!retType.Valid) // Type should be null for budget assignments
					is.Equal(
						retAccountUUID, incomeCategoryUUID,
					) // Account should be Income
					is.Equal(
						retCategoryUUID, groceriesCategoryUUID,
					)                           // Category should be Groceries
					is.True(retMetadata == nil) // Metadata should be null initially

					transactionUUID = retUUID // Store for verification
				},
			)

			// 2. Verify Database State (Transaction)
			t.Run(
				"VerifyTransaction", func(t *testing.T) {
					is := is_.New(t)
					if transactionUUID == "" {
						t.Skip("Skipping VerifyTransaction because transaction UUID was not captured")
					}

					// Since api.assign_to_category creates a transaction directly in data.transactions,
					// we need to query it directly to verify the details
					var (
						dbLedgerUUID      string
						dbDescription     string
						dbDate            time.Time
						dbAmount          int64
						dbDebitAccountID  int
						dbCreditAccountID int
						dbUserData        string
					)

					// Query the transaction from data.transactions
					err = conn.QueryRow(
						ctx,
						`SELECT l.uuid, t.description, t.date, t.amount, t.debit_account_id, t.credit_account_id, t.user_data
						 FROM data.transactions t
						 JOIN data.ledgers l ON t.ledger_id = l.id
						 WHERE t.uuid = $1`,
						transactionUUID,
					).Scan(
						&dbLedgerUUID,
						&dbDescription,
						&dbDate,
						&dbAmount,
						&dbDebitAccountID,
						&dbCreditAccountID,
						&dbUserData,
					)
					is.NoErr(err) // Should find transaction

					is.Equal(
						dbLedgerUUID, ledgerUUID,
					) // Ledger UUID should match
					is.Equal(
						dbDescription, assignDesc,
					) // Description should match
					is.Equal(
						dbAmount, assignAmount,
					) // Amount should match
					is.Equal(
						dbUserData, testUserID,
					)                                            // User data should match
					is.True(dbDate.Unix()-assignDate.Unix() < 2) // Check time

					// Verify that the transaction debits Income and credits the target category
					// We need to get the account IDs for Income and the target category
					var incomeAccountID, groceriesCategoryID int
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.accounts WHERE uuid = $1",
						incomeCategoryUUID,
					).Scan(&incomeAccountID)
					is.NoErr(err) // Should find Income account

					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.accounts WHERE uuid = $1",
						groceriesCategoryUUID,
					).Scan(&groceriesCategoryID)
					is.NoErr(err) // Should find Groceries category

					is.Equal(
						dbDebitAccountID, incomeAccountID,
					) // Debit should be Income
					is.Equal(
						dbCreditAccountID, groceriesCategoryID,
					) // Credit should be Groceries
				},
			)

			// 3. Verify Final Balances
			t.Run(
				"VerifyBalances", func(t *testing.T) {
					is := is_.New(t)
					if transactionUUID == "" { // Use transactionUUID as proxy for success of previous step
						t.Skip("Skipping VerifyBalances because assignment transaction was not created")
					}

					finalIncomeBalance, err := getBalance(incomeCategoryUUID)
					is.NoErr(err)
					finalGroceriesBalance, err := getBalance(groceriesCategoryUUID)
					is.NoErr(err)

					is.Equal(
						finalIncomeBalance, initialIncomeBalance-assignAmount,
					) // Income balance should decrease
					is.Equal(
						finalGroceriesBalance,
						initialGroceriesBalance+assignAmount,
					) // Groceries balance should increase
				},
			)

			// 4. Error Cases
			t.Run(
				"InvalidLedgerError", func(t *testing.T) {
					is := is_.New(t)
					invalidLedgerUUID := "00000000-0000-0000-0000-000000000000"
					_, err := conn.Exec(
						ctx,
						"SELECT api.assign_to_category($1, $2, $3, $4, $5)",
						invalidLedgerUUID, time.Now(), "Fail Assign", 1000,
						groceriesCategoryUUID,
					)
					is.True(err != nil) // Should return an error

					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr)) // Error should be a PgError

					// Check message from utils function
					is.True(
						strings.Contains(
							pgErr.Message, "not found for current user",
						),
					)
				},
			)

			t.Run(
				"InvalidCategoryError", func(t *testing.T) {
					is := is_.New(t)
					invalidCategoryUUID := "00000000-0000-0000-0000-000000000000"
					_, err := conn.Exec(
						ctx,
						"SELECT api.assign_to_category($1, $2, $3, $4, $5)",
						ledgerUUID, time.Now(), "Fail Assign", 1000,
						invalidCategoryUUID,
					)
					is.True(err != nil)
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr))
					is.True(
						strings.Contains(
							pgErr.Message, "Category with UUID",
						),
					) // Check message from utils function
					is.True(
						strings.Contains(
							pgErr.Message, "not found or does not belong",
						),
					)
				},
			)

			t.Run(
				"ZeroAmountError", func(t *testing.T) {
					is := is_.New(t)
					_, err := conn.Exec(
						ctx,
						"SELECT api.assign_to_category($1, $2, $3, $4, $5)",
						ledgerUUID, time.Now(), "Zero Assign", 0,
						groceriesCategoryUUID,
					)
					is.True(err != nil)
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr))
					is.True(
						strings.Contains(
							pgErr.Message, "Assignment amount must be positive",
						),
					) // Check message from utils function
				},
			)

			t.Run(
				"NegativeAmountError", func(t *testing.T) {
					is := is_.New(t)
					_, err := conn.Exec(
						ctx,
						"SELECT api.assign_to_category($1, $2, $3, $4, $5)",
						ledgerUUID, time.Now(), "Negative Assign", -1000,
						groceriesCategoryUUID,
					)
					is.True(err != nil)
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr))
					is.True(
						strings.Contains(
							pgErr.Message, "Assignment amount must be positive",
						),
					) // Check message from utils function
				},
			)

		},
	)


	// // Test account creation using the ledger created above
	// t.Run(
	// 	"CreateAccounts", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// // Test the find_category function
	// t.Run(
	// 	"FindCategory", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// Test the api.get_budget_status function
	t.Run(
		"BudgetStatus", func(t *testing.T) {
			is := is_.New(t)
			
			// Create a new ledger specifically for this test
			var budgetStatusLedgerUUID string
			var budgetStatusLedgerID int
			
			// Create a new ledger using the api.ledgers view
			ledgerName := "BudgetStatus Test Ledger"
			err := conn.QueryRow(
				ctx,
				"insert into api.ledgers (name) values ($1) returning uuid",
				ledgerName,
			).Scan(&budgetStatusLedgerUUID)
			is.NoErr(err) // should create ledger without error
			
			// Get the internal ID for verification
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.ledgers WHERE uuid = $1",
				budgetStatusLedgerUUID,
			).Scan(&budgetStatusLedgerID)
			is.NoErr(err) // should find the ledger by UUID
			is.True(budgetStatusLedgerID > 0) // should have a valid internal ID
			
			// Setup accounts for testing
			var (
				checkingAccountUUID string
				checkingAccountID   int
				groceriesCategoryUUID string
				groceriesCategoryID   int
				rentCategoryUUID string
				rentCategoryID   int
				incomeAccountUUID string
				incomeAccountID int
			)
			
			// Create checking account
			err = conn.QueryRow(
				ctx,
				`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, 'asset') RETURNING uuid`,
				budgetStatusLedgerUUID, "Budget-Checking",
			).Scan(&checkingAccountUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				checkingAccountUUID,
			).Scan(&checkingAccountID)
			is.NoErr(err)
			
			// Create groceries category
			err = conn.QueryRow(
				ctx,
				"SELECT uuid FROM api.add_category($1, $2)",
				budgetStatusLedgerUUID, "Budget-Groceries",
			).Scan(&groceriesCategoryUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				groceriesCategoryUUID,
			).Scan(&groceriesCategoryID)
			is.NoErr(err)
			
			// Create rent category
			err = conn.QueryRow(
				ctx,
				"SELECT uuid FROM api.add_category($1, $2)",
				budgetStatusLedgerUUID, "Budget-Rent",
			).Scan(&rentCategoryUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				rentCategoryUUID,
			).Scan(&rentCategoryID)
			is.NoErr(err)
			
			// Get Income account UUID and ID
			err = conn.QueryRow(
				ctx,
				"SELECT utils.find_category($1, $2)",
				budgetStatusLedgerUUID, "Income",
			).Scan(&incomeAccountUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				incomeAccountUUID,
			).Scan(&incomeAccountID)
			is.NoErr(err)
			
			// Test initial budget status (should be empty)
			t.Run("InitialBudgetStatus", func(t *testing.T) {
				is := is_.New(t)
				
				// Query the api.get_budget_status function
				rows, err := conn.Query(
					ctx,
					"SELECT * FROM api.get_budget_status($1)",
					budgetStatusLedgerUUID,
				)
				is.NoErr(err)
				defer rows.Close()
				
				// Should have two categories but with zero balances
				var categories []struct {
					CategoryUUID string
					CategoryName string
					Budgeted     int64
					Activity     int64
					Balance      int64
				}
				
				for rows.Next() {
					var cat struct {
						CategoryUUID string
						CategoryName string
						Budgeted     int64
						Activity     int64
						Balance      int64
					}
					err := rows.Scan(
						&cat.CategoryUUID,
						&cat.CategoryName,
						&cat.Budgeted,
						&cat.Activity,
						&cat.Balance,
					)
					is.NoErr(err)
					categories = append(categories, cat)
				}
				is.NoErr(rows.Err())
				
				// Should have two categories (Groceries and Rent)
				is.Equal(len(categories), 2)
				
				// All values should be zero initially
				for _, cat := range categories {
					is.Equal(cat.Budgeted, int64(0))
					is.Equal(cat.Activity, int64(0))
					is.Equal(cat.Balance, int64(0))
				}
			})
			
			// Add transactions and test budget status
			t.Run("TransactionsAndBudgetStatus", func(t *testing.T) {
				is := is_.New(t)
				
				// 1. Add income transaction (inflow to checking from income)
				incomeAmount := int64(200000) // $2000.00
				var incomeTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'inflow', $4, $5, $6) RETURNING uuid`,
					budgetStatusLedgerUUID, time.Now(), "Paycheck", incomeAmount,
					checkingAccountUUID, incomeAccountUUID,
				).Scan(&incomeTxUUID)
				is.NoErr(err)
				
				// 2. Assign money to Groceries category
				groceriesBudgetAmount := int64(50000) // $500.00
				var groceriesBudgetTxUUID string
				err = conn.QueryRow(
					ctx,
					"SELECT uuid FROM api.assign_to_category($1, $2, $3, $4, $5)",
					budgetStatusLedgerUUID, time.Now(), "Budget: Groceries", groceriesBudgetAmount,
					groceriesCategoryUUID,
				).Scan(&groceriesBudgetTxUUID)
				is.NoErr(err)
				
				// 3. Assign money to Rent category
				rentBudgetAmount := int64(100000) // $1000.00
				var rentBudgetTxUUID string
				err = conn.QueryRow(
					ctx,
					"SELECT uuid FROM api.assign_to_category($1, $2, $3, $4, $5)",
					budgetStatusLedgerUUID, time.Now(), "Budget: Rent", rentBudgetAmount,
					rentCategoryUUID,
				).Scan(&rentBudgetTxUUID)
				is.NoErr(err)
				
				// 4. Spend money from Groceries
				groceriesSpendAmount := int64(20000) // $200.00
				var groceriesSpendTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
					budgetStatusLedgerUUID, time.Now(), "Grocery Shopping", groceriesSpendAmount,
					checkingAccountUUID, groceriesCategoryUUID,
				).Scan(&groceriesSpendTxUUID)
				is.NoErr(err)
				
				// 5. Spend money from Rent
				rentSpendAmount := int64(100000) // $1000.00 (full amount)
				var rentSpendTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
					budgetStatusLedgerUUID, time.Now(), "Pay Rent", rentSpendAmount,
					checkingAccountUUID, rentCategoryUUID,
				).Scan(&rentSpendTxUUID)
				is.NoErr(err)
				
				// Check budget status after transactions
				rows, err := conn.Query(
					ctx,
					"SELECT * FROM api.get_budget_status($1)",
					budgetStatusLedgerUUID,
				)
				is.NoErr(err)
				defer rows.Close()
				
				var budgetStatus = make(map[string]struct {
					CategoryName string
					Budgeted     int64
					Activity     int64
					Balance      int64
				})
				
				for rows.Next() {
					var (
						categoryUUID string
						categoryName string
						budgeted     int64
						activity     int64
						balance      int64
					)
					err := rows.Scan(
						&categoryUUID,
						&categoryName,
						&budgeted,
						&activity,
						&balance,
					)
					is.NoErr(err)
					
					budgetStatus[categoryUUID] = struct {
						CategoryName string
						Budgeted     int64
						Activity     int64
						Balance      int64
					}{
						CategoryName: categoryName,
						Budgeted:     budgeted,
						Activity:     activity,
						Balance:      balance,
					}
				}
				is.NoErr(rows.Err())
				
				// Should have two categories
				is.Equal(len(budgetStatus), 2)
				
				// Check Groceries category
				groceriesStatus, exists := budgetStatus[groceriesCategoryUUID]
				is.True(exists) // Should find Groceries category
				is.Equal(groceriesStatus.CategoryName, "Budget-Groceries")
				is.Equal(groceriesStatus.Budgeted, groceriesBudgetAmount) // $500 budgeted
				is.Equal(groceriesStatus.Activity, -groceriesSpendAmount) // -$200 spent (negative for outflow)
				is.Equal(groceriesStatus.Balance, groceriesBudgetAmount - groceriesSpendAmount) // $300 remaining
				
				// Check Rent category
				rentStatus, exists := budgetStatus[rentCategoryUUID]
				is.True(exists) // Should find Rent category
				is.Equal(rentStatus.CategoryName, "Budget-Rent")
				is.Equal(rentStatus.Budgeted, rentBudgetAmount) // $1000 budgeted
				is.Equal(rentStatus.Activity, -rentSpendAmount) // -$1000 spent (negative for outflow)
				is.Equal(rentStatus.Balance, rentBudgetAmount - rentSpendAmount) // $0 remaining (fully spent)
			})
			
			// Test error cases
			t.Run("ErrorCases", func(t *testing.T) {
				is := is_.New(t)
				
				// Test with invalid ledger UUID
				invalidLedgerUUID := "invalid-uuid-that-does-not-exist"
				
				// Use QueryRow instead of Query to force immediate execution
				var (
					categoryUUID string
					categoryName string
					budgeted     int64
					activity     int64
					balance      int64
				)
				
				err = conn.QueryRow(
					ctx,
					"SELECT * FROM api.get_budget_status($1) LIMIT 1",
					invalidLedgerUUID,
				).Scan(
					&categoryUUID,
					&categoryName,
					&budgeted,
					&activity,
					&balance,
				)
				
				// The actual test assertion
				is.True(err != nil) // Should return an error
				
				// Check error message
				var pgErr *pgconn.PgError
				if errors.As(err, &pgErr) {
					is.True(strings.Contains(pgErr.Message, "not found for current user"))
				}
			})
		},
	)

	// Test the get_account_balance function
	t.Run(
		"GetAccountBalance", func(t *testing.T) {
			is := is_.New(t)
			
			// Create a new ledger specifically for this test
			var balanceTestLedgerUUID string
			var balanceTestLedgerID int
			
			// Create a new ledger using the api.ledgers view
			ledgerName := "GetAccountBalance Test Ledger"
			err := conn.QueryRow(
				ctx,
				"insert into api.ledgers (name) values ($1) returning uuid",
				ledgerName,
			).Scan(&balanceTestLedgerUUID)
			is.NoErr(err) // should create ledger without error
			
			// Get the internal ID for verification
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.ledgers WHERE uuid = $1",
				balanceTestLedgerUUID,
			).Scan(&balanceTestLedgerID)
			is.NoErr(err) // should find the ledger by UUID
			is.True(balanceTestLedgerID > 0) // should have a valid internal ID
			
			// Setup accounts for testing
			var (
				checkingAccountUUID string
				checkingAccountID   int
				groceriesCategoryUUID string
				groceriesCategoryID   int
				incomeAccountUUID string
				incomeAccountID int
			)
			
			// Create checking account
			err = conn.QueryRow(
				ctx,
				`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, 'asset') RETURNING uuid`,
				balanceTestLedgerUUID, "Balance-Checking",
			).Scan(&checkingAccountUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				checkingAccountUUID,
			).Scan(&checkingAccountID)
			is.NoErr(err)
			
			// Create groceries category
			err = conn.QueryRow(
				ctx,
				"SELECT uuid FROM api.add_category($1, $2)",
				balanceTestLedgerUUID, "Balance-Groceries",
			).Scan(&groceriesCategoryUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				groceriesCategoryUUID,
			).Scan(&groceriesCategoryID)
			is.NoErr(err)
			
			// Get Income account UUID and ID
			err = conn.QueryRow(
				ctx,
				"SELECT utils.find_category($1, $2)",
				balanceTestLedgerUUID, "Income",
			).Scan(&incomeAccountUUID)
			is.NoErr(err)
			
			// Get internal ID
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.accounts WHERE uuid = $1",
				incomeAccountUUID,
			).Scan(&incomeAccountID)
			is.NoErr(err)
			
			// Test initial balances (should be zero)
			t.Run("InitialBalances", func(t *testing.T) {
				is := is_.New(t)
				
				// Check initial balance for checking account
				var checkingBalance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&checkingBalance)
				is.NoErr(err)
				is.Equal(checkingBalance, int64(0)) // Initial balance should be zero
				
				// Check initial balance for groceries category
				var groceriesBalance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, groceriesCategoryID,
				).Scan(&groceriesBalance)
				is.NoErr(err)
				is.Equal(groceriesBalance, int64(0)) // Initial balance should be zero
			})
			
			// Add transactions and test balances
			t.Run("TransactionsAndBalances", func(t *testing.T) {
				is := is_.New(t)
				
				// 1. Add income transaction (inflow to checking from income)
				incomeAmount := int64(100000) // $1000.00
				var incomeTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'inflow', $4, $5, $6) RETURNING uuid`,
					balanceTestLedgerUUID, time.Now(), "Initial Income", incomeAmount,
					checkingAccountUUID, incomeAccountUUID,
				).Scan(&incomeTxUUID)
				is.NoErr(err)
				
				// Check balances after income
				var checkingBalance, incomeBalance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&checkingBalance)
				is.NoErr(err)
				is.Equal(checkingBalance, incomeAmount) // Checking should have the income amount
				
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, incomeAccountID,
				).Scan(&incomeBalance)
				is.NoErr(err)
				is.Equal(incomeBalance, incomeAmount) // Income should have the income amount
				
				// 2. Add spending transaction (outflow from checking to groceries)
				spendAmount := int64(25000) // $250.00
				var spendTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
					balanceTestLedgerUUID, time.Now(), "Grocery Shopping", spendAmount,
					checkingAccountUUID, groceriesCategoryUUID,
				).Scan(&spendTxUUID)
				is.NoErr(err)
				
				// Check balances after spending
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&checkingBalance)
				is.NoErr(err)
				is.Equal(checkingBalance, incomeAmount - spendAmount) // Checking should be reduced by spend amount
				
				var groceriesBalance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, groceriesCategoryID,
				).Scan(&groceriesBalance)
				is.NoErr(err)
				is.Equal(groceriesBalance, -spendAmount) // Groceries should be negative spend amount
				
				// 3. Add another spending transaction that will be soft-deleted
				deletedSpendAmount := int64(15000) // $150.00
				var deletedTxUUID string
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
					 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
					balanceTestLedgerUUID, time.Now(), "To Be Deleted", deletedSpendAmount,
					checkingAccountUUID, groceriesCategoryUUID,
				).Scan(&deletedTxUUID)
				is.NoErr(err)
				
				// Check balances after second spending
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&checkingBalance)
				is.NoErr(err)
				is.Equal(checkingBalance, incomeAmount - spendAmount - deletedSpendAmount) // Checking further reduced
				
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, groceriesCategoryID,
				).Scan(&groceriesBalance)
				is.NoErr(err)
				is.Equal(groceriesBalance, -(spendAmount + deletedSpendAmount)) // Groceries further reduced
				
				// 4. Soft-delete the second transaction
				_, err = conn.Exec(
					ctx,
					`DELETE FROM api.transactions WHERE uuid = $1`,
					deletedTxUUID,
				)
				is.NoErr(err)
				
				// Verify transaction is soft-deleted (deleted_at is set)
				var deletedAt pgtype.Timestamptz
				err = conn.QueryRow(
					ctx,
					"SELECT deleted_at FROM data.transactions WHERE uuid = $1",
					deletedTxUUID,
				).Scan(&deletedAt)
				is.NoErr(err)
				is.True(deletedAt.Valid) // deleted_at should be set
				
				// Check balances after soft-delete - should exclude the deleted transaction
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&checkingBalance)
				is.NoErr(err)
				is.Equal(checkingBalance, incomeAmount - spendAmount) // Should be back to balance after first spend
				
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, groceriesCategoryID,
				).Scan(&groceriesBalance)
				is.NoErr(err)
				is.Equal(groceriesBalance, -spendAmount) // Should be back to balance after first spend
			})
			
			// Test error cases
			t.Run("ErrorCases", func(t *testing.T) {
				is := is_.New(t)
				
				// Test with invalid account ID
				var invalidBalance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, 999999, // Invalid account ID
				).Scan(&invalidBalance)
				is.True(err != nil) // Should return an error
				
				// Test with account from different ledger
				// First create a different ledger and account
				var otherLedgerUUID string
				var otherLedgerID int
				err = conn.QueryRow(
					ctx,
					"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
					"Other Test Ledger",
				).Scan(&otherLedgerUUID)
				is.NoErr(err)
				
				err = conn.QueryRow(
					ctx,
					"SELECT id FROM data.ledgers WHERE uuid = $1",
					otherLedgerUUID,
				).Scan(&otherLedgerID)
				is.NoErr(err)
				
				var otherAccountUUID string
				var otherAccountID int
				err = conn.QueryRow(
					ctx,
					`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, 'asset') RETURNING uuid`,
					otherLedgerUUID, "Other Checking",
				).Scan(&otherAccountUUID)
				is.NoErr(err)
				
				err = conn.QueryRow(
					ctx,
					"SELECT id FROM data.accounts WHERE uuid = $1",
					otherAccountUUID,
				).Scan(&otherAccountID)
				is.NoErr(err)
				
				// Try to get balance of account from one ledger using another ledger's ID
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, otherAccountID,
				).Scan(&invalidBalance)
				is.True(err != nil) // Should return an error
				
				// Check error message
				var pgErr *pgconn.PgError
				is.True(errors.As(err, &pgErr))
				is.True(strings.Contains(pgErr.Message, "account not found or does not belong to the specified ledger"))
			})
			
			// Compare with balances table
			t.Run("CompareWithBalancesTable", func(t *testing.T) {
				is := is_.New(t)
				
				// Get balance using get_account_balance function
				var balance int64
				err = conn.QueryRow(
					ctx,
					"SELECT utils.get_account_balance($1, $2)",
					balanceTestLedgerID, checkingAccountID,
				).Scan(&balance)
				is.NoErr(err)
				
				// Verify balance is correct based on transactions
				expectedBalance := int64(100000) - int64(25000) // Income - spending
				is.Equal(balance, expectedBalance)
			})
		},
	)

	// // Test the balances table and trigger functionality
	// t.Run(
	// 	"BalancesTracking", func(t *testing.T) { // This is the one being added
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// Test the api.add_categories function
	t.Run("AddCategories", func(t *testing.T) {
		is := is_.New(t)
		
		// Create a new ledger specifically for this test
		var batchCategoriesLedgerUUID string
		var batchCategoriesLedgerID int
		
		// Create a new ledger using the api.ledgers view
		ledgerName := "Batch Categories Test Ledger"
		err := conn.QueryRow(
			ctx,
			"insert into api.ledgers (name) values ($1) returning uuid",
			ledgerName,
		).Scan(&batchCategoriesLedgerUUID)
		is.NoErr(err) // should create ledger without error
		
		// Get the internal ID for verification
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.ledgers WHERE uuid = $1",
			batchCategoriesLedgerUUID,
		).Scan(&batchCategoriesLedgerID)
		is.NoErr(err) // should find the ledger by UUID
		is.True(batchCategoriesLedgerID > 0) // should have a valid internal ID
		
		// Test successful batch category creation
		t.Run("Success", func(t *testing.T) {
			is := is_.New(t)
			
			// Define category names to create
			categoryNames := []string{"Food", "Entertainment", "Transportation"}
			
			// Call the api.add_categories function with Go slice
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.add_categories($1, $2)",
				batchCategoriesLedgerUUID, categoryNames,
			)
			is.NoErr(err) // should execute function without error
			defer rows.Close()
			
			// Collect the returned categories
			var createdCategories []struct {
				UUID        string
				Name        string
				Type        string
				Description pgtype.Text
				Metadata    *[]byte
				UserData    string
				LedgerUUID  string
			}
			
			for rows.Next() {
				var cat struct {
					UUID        string
					Name        string
					Type        string
					Description pgtype.Text
					Metadata    *[]byte
					UserData    string
					LedgerUUID  string
				}
				err := rows.Scan(
					&cat.UUID,
					&cat.Name,
					&cat.Type,
					&cat.Description,
					&cat.Metadata,
					&cat.UserData,
					&cat.LedgerUUID,
				)
				is.NoErr(err)
				createdCategories = append(createdCategories, cat)
			}
			is.NoErr(rows.Err())
			
			// Should have created all categories
			is.Equal(len(createdCategories), len(categoryNames))
			
			// Verify each category was created correctly
			for i, cat := range createdCategories {
				is.True(cat.UUID != "") // Should have a valid UUID
				is.Equal(cat.Name, categoryNames[i]) // Name should match input
				is.Equal(cat.Type, "equity") // Type should be equity
				is.Equal(cat.LedgerUUID, batchCategoriesLedgerUUID) // Ledger UUID should match
				is.Equal(cat.UserData, testUserID) // User data should match
				is.True(!cat.Description.Valid) // Description should be null
				is.True(cat.Metadata == nil) // Metadata should be null
				
				// Verify the category exists in the database
				var exists bool
				err := conn.QueryRow(
					ctx,
					"SELECT EXISTS(SELECT 1 FROM data.accounts WHERE uuid = $1 AND name = $2)",
					cat.UUID, cat.Name,
				).Scan(&exists)
				is.NoErr(err)
				is.True(exists) // Category should exist in database
			}
		})
		
		// Test with empty array (should return empty result)
		t.Run("EmptyArray", func(t *testing.T) {
			is := is_.New(t)
			
			// Call with empty array
			emptyArray := []string{} // Empty Go string slice
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.add_categories($1, $2)",
				batchCategoriesLedgerUUID, emptyArray,
			)
			is.NoErr(err) // should execute without error
			defer rows.Close()
			
			// Should return no rows
			var count int
			for rows.Next() {
				count++
			}
			is.NoErr(rows.Err())
			is.Equal(count, 0) // Should have no results
		})
		
		// Test with array containing empty strings (should skip them)
		t.Run("EmptyStrings", func(t *testing.T) {
			is := is_.New(t)
			
			// Call with array containing empty strings
			mixedArray := []string{"Valid", "", " ", "Valid2"} // Go string slice
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.add_categories($1, $2)",
				batchCategoriesLedgerUUID, mixedArray,
			)
			is.NoErr(err) // should execute without error
			defer rows.Close()
			
			// Collect the returned categories
			var createdCategories []struct {
				UUID string
				Name string
			}
			
			for rows.Next() {
				var cat struct {
					UUID        string
					Name        string
					Type        string
					Description pgtype.Text
					Metadata    *[]byte
					UserData    string
					LedgerUUID  string
				}
				err := rows.Scan(
					&cat.UUID,
					&cat.Name,
					&cat.Type,
					&cat.Description,
					&cat.Metadata,
					&cat.UserData,
					&cat.LedgerUUID,
				)
				is.NoErr(err)
				createdCategories = append(createdCategories, struct {
					UUID string
					Name string
				}{
					UUID: cat.UUID,
					Name: cat.Name,
				})
			}
			is.NoErr(rows.Err())
			
			// Should have created only the valid categories
			is.Equal(len(createdCategories), 2)
			
			// Verify the names
			validNames := []string{"Valid", "Valid2"}
			for i, cat := range createdCategories {
				is.Equal(cat.Name, validNames[i])
			}
		})
		
		// Test with duplicate category names (should fail)
		t.Run("DuplicateNames", func(t *testing.T) {
			is := is_.New(t)
			
			// First create a category
			var singleCatUUID string
			err := conn.QueryRow(
				ctx,
				"SELECT uuid FROM api.add_category($1, $2)",
				batchCategoriesLedgerUUID, "Unique",
			).Scan(&singleCatUUID)
			is.NoErr(err) // should create category without error
			
			// Now try to create a batch with the same name
			duplicateArray := []string{"New", "Unique", "Another"} // Go string slice
			_, err = conn.Exec(
				ctx,
				"SELECT * FROM api.add_categories($1, $2)",
				batchCategoriesLedgerUUID, duplicateArray,
			)
			is.True(err != nil) // should return an error
			
			// Check for specific error message
			var pgErr *pgconn.PgError
			is.True(errors.As(err, &pgErr)) // Error should be a PgError
			is.True(strings.Contains(pgErr.Message, "Category with name \"Unique\" already exists in this ledger"))
		})
		
		// Test with invalid ledger UUID
		t.Run("InvalidLedger", func(t *testing.T) {
			is := is_.New(t)
			
			invalidLedgerUUID := "00000000-0000-0000-0000-000000000000"
			
			testArray := []string{"Test1", "Test2"} // Go string slice
			_, err := conn.Exec(
				ctx,
				"SELECT * FROM api.add_categories($1, $2)",
				invalidLedgerUUID, testArray,
			)
			is.True(err != nil) // should return an error
			
			// Check for specific error message
			var pgErr *pgconn.PgError
			is.True(errors.As(err, &pgErr)) // Error should be a PgError
			is.True(strings.Contains(pgErr.Message, "not found for current user"))
		})
	})

	// Test the api.get_account_transactions function
	t.Run("AccountTransactions", func(t *testing.T) {
		is := is_.New(t)
		
		// Create a new ledger specifically for this test
		var txLedgerUUID string
		var txLedgerID int
		
		// Create a new ledger using the api.ledgers view
		ledgerName := "AccountTransactions Test Ledger"
		err := conn.QueryRow(
			ctx,
			"insert into api.ledgers (name) values ($1) returning uuid",
			ledgerName,
		).Scan(&txLedgerUUID)
		is.NoErr(err) // should create ledger without error
		
		// Get the internal ID for verification
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.ledgers WHERE uuid = $1",
			txLedgerUUID,
		).Scan(&txLedgerID)
		is.NoErr(err) // should find the ledger by UUID
		is.True(txLedgerID > 0) // should have a valid internal ID
		
		// Setup accounts for testing
		var (
			checkingAccountUUID string
			checkingAccountID   int
			groceriesCategoryUUID string
			groceriesCategoryID   int
			rentCategoryUUID string
			rentCategoryID   int
			incomeAccountUUID string
			incomeAccountID int
		)
		
		// Create checking account
		err = conn.QueryRow(
			ctx,
			`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, 'asset') RETURNING uuid`,
			txLedgerUUID, "Tx-Checking",
		).Scan(&checkingAccountUUID)
		is.NoErr(err)
		
		// Get internal ID
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE uuid = $1",
			checkingAccountUUID,
		).Scan(&checkingAccountID)
		is.NoErr(err)
		
		// Create groceries category
		err = conn.QueryRow(
			ctx,
			"SELECT uuid FROM api.add_category($1, $2)",
			txLedgerUUID, "Tx-Groceries",
		).Scan(&groceriesCategoryUUID)
		is.NoErr(err)
		
		// Get internal ID
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE uuid = $1",
			groceriesCategoryUUID,
		).Scan(&groceriesCategoryID)
		is.NoErr(err)
		
		// Create rent category
		err = conn.QueryRow(
			ctx,
			"SELECT uuid FROM api.add_category($1, $2)",
			txLedgerUUID, "Tx-Rent",
		).Scan(&rentCategoryUUID)
		is.NoErr(err)
		
		// Get internal ID
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE uuid = $1",
			rentCategoryUUID,
		).Scan(&rentCategoryID)
		is.NoErr(err)
		
		// Get Income account UUID and ID
		err = conn.QueryRow(
			ctx,
			"SELECT utils.find_category($1, $2)",
			txLedgerUUID, "Income",
		).Scan(&incomeAccountUUID)
		is.NoErr(err)
		
		// Get internal ID
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE uuid = $1",
			incomeAccountUUID,
		).Scan(&incomeAccountID)
		is.NoErr(err)
		
		// Test initial account transactions (should be empty)
		t.Run("InitialAccountTransactions", func(t *testing.T) {
			is := is_.New(t)
			
			// Query the api.get_account_transactions function
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.get_account_transactions($1)",
				checkingAccountUUID,
			)
			is.NoErr(err)
			defer rows.Close()
			
			// Should have no transactions initially
			var transactions []struct {
				Date        time.Time
				Category    string
				Description string
				Type        string
				Amount      int64
			}
			
			for rows.Next() {
				var tx struct {
					Date        time.Time
					Category    string
					Description string
					Type        string
					Amount      int64
				}
				err := rows.Scan(
					&tx.Date,
					&tx.Category,
					&tx.Description,
					&tx.Type,
					&tx.Amount,
				)
				is.NoErr(err)
				transactions = append(transactions, tx)
			}
			is.NoErr(rows.Err())
			
			// Should have no transactions initially
			is.Equal(len(transactions), 0)
		})
		
		// Add transactions and test account transactions
		t.Run("TransactionsAndAccountHistory", func(t *testing.T) {
			is := is_.New(t)
			
			// Create a series of transactions with different dates to test ordering
			
			// 1. Add income transaction (inflow to checking from income) - oldest
			incomeAmount := int64(100000) // $1000.00
			incomeDate := time.Now().Add(-48 * time.Hour) // 2 days ago
			var incomeTxUUID string
			err = conn.QueryRow(
				ctx,
				`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
				 VALUES ($1, $2, $3, 'inflow', $4, $5, $6) RETURNING uuid`,
				txLedgerUUID, incomeDate, "Initial Paycheck", incomeAmount,
				checkingAccountUUID, incomeAccountUUID,
			).Scan(&incomeTxUUID)
			is.NoErr(err)
			
			// 2. Add rent payment (outflow from checking to rent) - middle date
			rentAmount := int64(50000) // $500.00
			rentDate := time.Now().Add(-24 * time.Hour) // 1 day ago
			var rentTxUUID string
			err = conn.QueryRow(
				ctx,
				`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
				 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
				txLedgerUUID, rentDate, "Rent Payment", rentAmount,
				checkingAccountUUID, rentCategoryUUID,
			).Scan(&rentTxUUID)
			is.NoErr(err)
			
			// 3. Add groceries transaction (outflow from checking to groceries) - newest
			groceriesAmount := int64(15000) // $150.00
			groceriesDate := time.Now() // Today
			var groceriesTxUUID string
			err = conn.QueryRow(
				ctx,
				`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
				 VALUES ($1, $2, $3, 'outflow', $4, $5, $6) RETURNING uuid`,
				txLedgerUUID, groceriesDate, "Grocery Shopping", groceriesAmount,
				checkingAccountUUID, groceriesCategoryUUID,
			).Scan(&groceriesTxUUID)
			is.NoErr(err)
			
			// Query account transactions
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.get_account_transactions($1)",
				checkingAccountUUID,
			)
			is.NoErr(err)
			defer rows.Close()
			
			var transactions []struct {
				Date        time.Time
				Category    string
				Description string
				Type        string
				Amount      int64
			}
			
			for rows.Next() {
				var tx struct {
					Date        time.Time
					Category    string
					Description string
					Type        string
					Amount      int64
				}
				err := rows.Scan(
					&tx.Date,
					&tx.Category,
					&tx.Description,
					&tx.Type,
					&tx.Amount,
				)
				is.NoErr(err)
				transactions = append(transactions, tx)
			}
			is.NoErr(rows.Err())
			
			// Should have 3 transactions
			is.Equal(len(transactions), 3)
			
			// Transactions should be ordered by date (newest first)
			is.Equal(transactions[0].Description, "Grocery Shopping") // Newest transaction first
			is.Equal(transactions[1].Description, "Rent Payment")     // Middle transaction second
			is.Equal(transactions[2].Description, "Initial Paycheck") // Oldest transaction last
			
			// Check transaction details
			// First transaction (newest - groceries)
			is.Equal(transactions[0].Category, "Tx-Groceries")
			is.Equal(transactions[0].Type, "outflow")
			is.Equal(transactions[0].Amount, groceriesAmount)
			
			// Second transaction (middle - rent)
			is.Equal(transactions[1].Category, "Tx-Rent")
			is.Equal(transactions[1].Type, "outflow")
			is.Equal(transactions[1].Amount, rentAmount)
			
			// Third transaction (oldest - income)
			is.Equal(transactions[2].Category, "Income")
			is.Equal(transactions[2].Type, "inflow")
			is.Equal(transactions[2].Amount, incomeAmount)
		})
		
		// Test transactions for a category account
		t.Run("CategoryTransactions", func(t *testing.T) {
			is := is_.New(t)
			
			// Query transactions for the groceries category
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.get_account_transactions($1)",
				groceriesCategoryUUID,
			)
			is.NoErr(err)
			defer rows.Close()
			
			var transactions []struct {
				Date        time.Time
				Category    string
				Description string
				Type        string
				Amount      int64
			}
			
			for rows.Next() {
				var tx struct {
					Date        time.Time
					Category    string
					Description string
					Type        string
					Amount      int64
				}
				err := rows.Scan(
					&tx.Date,
					&tx.Category,
					&tx.Description,
					&tx.Type,
					&tx.Amount,
				)
				is.NoErr(err)
				transactions = append(transactions, tx)
			}
			is.NoErr(rows.Err())
			
			// Should have 1 transaction for groceries category
			is.Equal(len(transactions), 1)
			
			// Check transaction details
			is.Equal(transactions[0].Category, "Tx-Checking") // For category accounts, the other account is shown
			is.Equal(transactions[0].Description, "Grocery Shopping")
			is.Equal(transactions[0].Type, "outflow") // For liability-like accounts, debits are outflows
			is.Equal(transactions[0].Amount, int64(15000))
		})
		
		// Test error cases
		t.Run("ErrorCases", func(t *testing.T) {
			is := is_.New(t)
			
			// Test with invalid account UUID
			invalidAccountUUID := "invalid-uuid-that-does-not-exist"
			
			// Use QueryRow instead of Query to force immediate execution
			var (
				date        time.Time
				category    string
				description string
				txType      string
				amount      int64
			)
			
			err = conn.QueryRow(
				ctx,
				"SELECT * FROM api.get_account_transactions($1) LIMIT 1",
				invalidAccountUUID,
			).Scan(
				&date,
				&category,
				&description,
				&txType,
				&amount,
			)
			
			// The actual test assertion
			is.True(err != nil) // Should return an error
			
			// Check error message
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) {
				is.True(strings.Contains(pgErr.Message, "not found for current user"))
			}
		})
	})
}
