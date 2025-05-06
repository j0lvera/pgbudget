package main

import (
	"context"
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

	// 5. Add Income Transaction via simple_transactions view
	var incomeTxUUID string
	err = conn.QueryRow(
		ctx,
		`INSERT INTO api.simple_transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`,
		ledgerUUID, "2023-01-01", "Salary deposit", "inflow", 100000,
		checkingUUID, incomeUUID,
	).Scan(&incomeTxUUID)
	if err != nil {
		err = fmt.Errorf(
			"failed to create income transaction via simple_transactions view: %w",
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

	// 7. Spend Money from Groceries via simple_transactions view
	var spendTxUUID string
	err = conn.QueryRow(
		ctx,
		`INSERT INTO api.simple_transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`,
		ledgerUUID, "2023-01-02", "Grocery shopping", "outflow", 7500,
		checkingUUID, groceriesUUID,
	).Scan(&spendTxUUID)
	if err != nil {
		err = fmt.Errorf(
			"failed to create spending transaction via simple_transactions view: %w",
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

	// Simulate PostgREST Authentication Context:
	// The application uses PostgREST, which sets 'request.jwt.claims' based on the user's JWT.
	// Database functions (like utils.get_user()) and RLS policies rely on this setting to identify the user.
	// Since tests connect directly via pgx, bypassing PostgREST, we must manually set a dummy
	// 'request.jwt.claims' for the session using set_config() so these functions work correctly.
	// IMPORTANT: The 'user_data' field within the JWT claims is used by utils.get_user()
	testUserID := "test_user_id_123"
	jwtClaims := fmt.Sprintf(
		`{"role": "test_user", "email": "test@example.com", "user_data": "%s"}`,
		testUserID,
	)
	// Use 'false' for session-local setting
	_, err = conn.Exec(
		ctx, `SELECT set_config('request.jwt.claims', $1, false)`, jwtClaims,
	)
	is.NoErr(err) // Should set config without error

	// --- VERIFICATION STEPS ---
	// 1. Verify the setting was applied and is readable (session-local)
	var readClaims string
	// Use 'false' for session-local setting
	err = conn.QueryRow(
		ctx, `SELECT current_setting('request.jwt.claims', false)`,
	).Scan(&readClaims)
	is.NoErr(err) // Should be able to read the setting back
	is.Equal(
		readClaims, jwtClaims,
	) // Setting read back should match what was set

	// 2. Verify the literal string can be cast to JSON directly
	_, err = conn.Exec(ctx, `SELECT $1::json`, jwtClaims)
	is.NoErr(err) // Should be able to cast the literal string to JSON without error
	// --- END OF VERIFICATION STEPS ---

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
	t.Run("Ledgers", func(t *testing.T) {
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
				is.NoErr(err)              // Should find the created ledger
				is.Equal(ledgerName, name) // Ledger should have the correct name

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

				log.Info().Interface("accounts", accountNames).Msg("Accounts")
				// According to README.md, we should have Income, Off-budget, and Unassigned accounts
				is.Equal(3, len(accountNames)) // Should have 3 default accounts
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
				is.Equal(updatedNameFromView, newLedgerName) // The name returned by RETURNING should be the new name

				// 2. Verify the name change by querying the api.ledgers view
				var nameFromView string
				err = conn.QueryRow(
					ctx,
					"SELECT name FROM api.ledgers WHERE uuid = $1",
					ledgerUUID,
				).Scan(&nameFromView)
				is.NoErr(err) // Should find the ledger in the view
				is.Equal(nameFromView, newLedgerName) // Name in view should be the new name

				// 3. Verify the name change by querying the data.ledgers table directly
				var nameFromDataTable string
				err = conn.QueryRow(ctx, "SELECT name FROM data.ledgers WHERE uuid = $1", ledgerUUID).Scan(&nameFromDataTable)
				is.NoErr(err) // Should find the ledger in the data table
				is.Equal(nameFromDataTable, newLedgerName) // Name in data table should be the new name
			},
		)
	})

	// Test account creation and update via api.accounts view
	var accountUUID string // To be set by CreateAccount and used by UpdateAccount
	var accountID int      // Internal ID for data.accounts verification

	// --- Account Tests ---
	t.Run("Accounts", func(t *testing.T) {
		t.Run("CreateAccount", func(t *testing.T) {
			is := is_.New(t)

			if ledgerUUID == "" {
				t.Skip("Skipping CreateAccount because ledgerUUID is not available")
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
			err := conn.QueryRow(ctx,
				`INSERT INTO api.accounts (ledger_uuid, name, type, description, metadata)
			 VALUES ($1, $2, $3, $4, $5)
			 RETURNING uuid, name, type, description, metadata, user_data, ledger_uuid`,
				ledgerUUID, accountName, accountType, accountDescription, accountMetadataInput,
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
			is.True(retUUID != "")                              // Should return a valid account UUID
			accountUUID = retUUID                               // Store for sub-test and further verification
			is.Equal(retName, accountName)                      // Name should match
			is.Equal(retType, accountType)                      // Type should match
			is.True(retDescription.Valid)                       // Description should be valid
			is.Equal(retDescription.String, accountDescription) // Description should match
			is.True(retMetadata != nil)                         // Metadata should not be nil
			is.Equal(string(*retMetadata), accountMetadataJSON) // Metadata should match
			is.Equal(retUserData, testUserID)                   // UserData should match the test user
			is.Equal(retLedgerUUID, ledgerUUID)                 // LedgerUUID should match the input

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
			err = conn.QueryRow(ctx,
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

			is.True(accountID > 0)                              // Should have a valid internal ID
			is.Equal(dbName, accountName)                       // Name in DB should match
			is.Equal(dbType, accountType)                       // Type in DB should match
			is.Equal(dbInternalType, "asset_like")              // Internal type should be correctly set by trigger
			is.True(dbDescription.Valid)                        // DB Description should be valid
			is.Equal(dbDescription.String, accountDescription)  // DB Description should match
			is.Equal(string(dbMetadata), accountMetadataJSON)   // DB Metadata should match
			is.Equal(dbUserData, testUserID)                    // DB UserData should match
			is.Equal(dbLedgerID, ledgerID)                      // DB LedgerID should match the parent ledger's internal ID
		})

		// Subtest for updating the account
		t.Run("UpdateAccount", func(t *testing.T) {
			is := is_.New(t)

			if accountUUID == "" {
				t.Skip("Skipping UpdateAccount because accountUUID is not available from CreateAccount")
			}

			newAccountName := "Updated Test Savings Account"

			// Update the account name via api.accounts view
			// Assumes an INSTEAD OF UPDATE trigger handles this if the view is complex.
			// If simple, PostgreSQL might handle it directly.
			var updatedNameFromView string
			err := conn.QueryRow(ctx,
				"UPDATE api.accounts SET name = $1 WHERE uuid = $2 RETURNING name",
				newAccountName, accountUUID,
			).Scan(&updatedNameFromView)
			is.NoErr(err) // Should update account name without error
			is.Equal(updatedNameFromView, newAccountName) // Name returned by RETURNING should be the new name

			// Verify name change by querying api.accounts view
			var nameFromView string
			err = conn.QueryRow(ctx, "SELECT name FROM api.accounts WHERE uuid = $1", accountUUID).Scan(&nameFromView)
			is.NoErr(err) // Should find the account in the view
			is.Equal(nameFromView, newAccountName) // Name in view should be the new name

			// Verify name change by querying data.accounts table
			var nameFromDataTable string
			err = conn.QueryRow(ctx, "SELECT name FROM data.accounts WHERE uuid = $1", accountUUID).Scan(&nameFromDataTable)
			is.NoErr(err) // Should find the account in the data table
			is.Equal(nameFromDataTable, newAccountName) // Name in data table should be the new name
		})
	})

	// --- Category Tests ---
	t.Run("Categories", func(t *testing.T) {
		// This is the subtest for creating a category
		t.Run("CreateCategory", func(t *testing.T) {
			// t.Skip("For now") // Removed/Commented

			// Skip if ledger creation failed
			if ledgerUUID == "" {
				t.Skip("Skipping CreateCategory tests because ledger creation failed or did not run")
			}

			is := is_.New(t)
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
						ledgerUUID, categoryName,
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
						retLedgerUUID, ledgerUUID,
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
						dbLedgerID, ledgerID,
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
						ctx, "SELECT api.add_category($1, $2)", ledgerUUID,
						categoryName,
					)
					is.True(err != nil) // Should return an error

					// Check for PostgreSQL unique violation error (code 23505)
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr)) // Error should be a PgError
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
					is.True(errors.As(err, &pgErr)) // Error should be a PgError
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
						ctx, "SELECT api.add_category($1, $2)", ledgerUUID, "",
					)
					is.True(err != nil) // Should return an error

					// Check for the specific error message from utils.add_category
					var pgErr *pgconn.PgError
					is.True(errors.As(err, &pgErr)) // Error should be a PgError
					// Check the Message field for the specific exception text raised by the function
					is.True(
						strings.Contains(
							pgErr.Message, "Category name cannot be empty",
						),
					)
				},
			)
		}) // End of t.Run("CreateCategory", ...)
	}) // End of t.Run("Categories", ...)

	// Test api.assign_to_category function
	t.Run(
		"AssignToCategory", func(t *testing.T) {
			t.Skip("For now") // This test can remain skipped
			// Retrieve the categoryUUID created in the AddCategory test block
			// This relies on test execution order or capturing the value at a higher scope.
			// For simplicity here, we re-fetch it. A better approach might involve
			// setting up a dedicated category within this test block or passing values.
			var groceriesCategoryUUID string
			t.Run(
				"Setup_FindGroceries", func(t *testing.T) {
					is := is_.New(t)
					if ledgerUUID == "" {
						t.Skip("Skipping because ledger UUID is not available")
					}
					err := conn.QueryRow(
						ctx,
						"SELECT uuid FROM data.accounts WHERE ledger_id = $1 AND name = $2",
						ledgerID, "Groceries",
					).Scan(&groceriesCategoryUUID)
					is.NoErr(err) // Should find Groceries category created in previous test
					is.True(groceriesCategoryUUID != "")
				},
			)

			// Skip subsequent tests if prerequisites failed
			if ledgerUUID == "" || groceriesCategoryUUID == "" {
				t.Skip("Skipping AssignToCategory tests because ledger or groceries category UUID is not available")
			}

			// Find Income category UUID
			var incomeCategoryUUID string
			err = conn.QueryRow(
				ctx,
				"SELECT uuid FROM data.accounts WHERE ledger_id = $1 AND name = $2",
				ledgerID, "Income",
			).Scan(&incomeCategoryUUID)
			is.NoErr(err) // Should find Income category
			is.True(incomeCategoryUUID != "")

			// --- Helper function to get balance ---
			getBalance := func(accountUUID string) (int64, error) {
				var balance int64
				// Query the data.balances table directly for verification
				// Need internal ID for the balances table join
				var accountID int
				err := conn.QueryRow(
					ctx, "SELECT id FROM data.accounts WHERE uuid = $1",
					accountUUID,
				).Scan(&accountID)
				if err != nil {
					return 0, fmt.Errorf(
						"failed to get account ID for UUID %s: %w", accountUUID,
						err,
					)
				}
				// Use COALESCE to handle cases where no balance record exists yet
				err = conn.QueryRow(
					ctx,
					"SELECT COALESCE((SELECT balance FROM data.balances WHERE account_id = $1 ORDER BY created_at DESC LIMIT 1), 0)",
					accountID,
				).Scan(&balance)
				if err != nil {
					// This check might be redundant now with COALESCE, but kept for safety
					if errors.Is(err, pgx.ErrNoRows) {
						return 0, nil // Treat no record as zero balance
					}
					return 0, fmt.Errorf(
						"failed to get balance for account ID %d: %w",
						accountID, err,
					)
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
						retUUID              string
						retDescription       string
						retAmount            int64
						retMetadata          *[]byte
						retDate              time.Time
						retLedgerUUID        string
						retDebitAccountUUID  string
						retCreditAccountUUID string
					)

					// Since it returns SETOF, QueryRow works if exactly one row is expected
					err := conn.QueryRow(
						ctx,
						"SELECT * FROM api.assign_to_category($1, $2, $3, $4, $5)",
						ledgerUUID, assignDate, assignDesc, assignAmount,
						groceriesCategoryUUID,
					).Scan(
						&retUUID,
						&retDescription,
						&retAmount,
						&retMetadata,
						&retDate,
						&retLedgerUUID,
						&retDebitAccountUUID,
						&retCreditAccountUUID,
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
					) // Ledger UUID should match
					is.Equal(
						retDebitAccountUUID, incomeCategoryUUID,
					) // Debit should be Income
					is.Equal(
						retCreditAccountUUID, groceriesCategoryUUID,
					)                           // Credit should be Groceries
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

					var (
						dbLedgerID        int
						dbDescription     string
						dbDate            time.Time
						dbAmount          int64
						dbDebitAccountID  int
						dbCreditAccountID int
						dbUserData        string
					)
					// Fetch internal IDs for comparison
					var incomeAccountID, groceriesAccountID int
					err = conn.QueryRow(
						ctx, "SELECT id FROM data.accounts WHERE uuid = $1",
						incomeCategoryUUID,
					).Scan(&incomeAccountID)
					is.NoErr(err)
					err = conn.QueryRow(
						ctx, "SELECT id FROM data.accounts WHERE uuid = $1",
						groceriesCategoryUUID,
					).Scan(&groceriesAccountID)
					is.NoErr(err)

					err = conn.QueryRow(
						ctx,
						`SELECT ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data
                 FROM data.transactions WHERE uuid = $1`, transactionUUID,
					).Scan(
						&dbLedgerID,
						&dbDescription,
						&dbDate,
						&dbAmount,
						&dbDebitAccountID,
						&dbCreditAccountID,
						&dbUserData,
					)
					is.NoErr(err) // Should find transaction

					is.Equal(dbLedgerID, ledgerID) // Ledger ID should match
					is.Equal(
						dbDescription, assignDesc,
					) // Description should match
					is.Equal(
						dbAmount, assignAmount,
					) // Amount should match
					is.Equal(
						dbDebitAccountID, incomeAccountID,
					) // Debit ID should be Income
					is.Equal(
						dbCreditAccountID, groceriesAccountID,
					) // Credit ID should be Groceries
					is.Equal(
						dbUserData, testUserID,
					)                                            // User data should match
					is.True(dbDate.Unix()-assignDate.Unix() < 2) // Check time
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

					log.Info().Int64(
						"initialIncome", initialIncomeBalance,
					).Int64("finalIncome", finalIncomeBalance).Int64(
						"assigned", assignAmount,
					).Msg("Income Balance Check")
					log.Info().Int64(
						"initialGroceries", initialGroceriesBalance,
					).Int64(
						"finalGroceries", finalGroceriesBalance,
					).Int64(
						"assigned", assignAmount,
					).Msg("Groceries Balance Check")

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

					// --- ADD LOGGING ---
					log.Error().Err(err).Str("Code", pgErr.Code).Str(
						"Message", pgErr.Message,
					).Str("Detail", pgErr.Detail).Str(
						"Hint", pgErr.Hint,
					).Msg("InvalidLedgerError details")
					// --- END LOGGING ---

					// Check message from utils function (keep existing check for now, will adjust after seeing log)
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

	// // Test the get_budget_status function with a fresh ledger
	// t.Run(
	// 	"GetBudgetStatus", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// // Test the get_account_balance function
	// t.Run(
	// 	"GetAccountBalance", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// // Test the balances table and trigger functionality
	// t.Run(
	// 	"BalancesTracking", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )

	// // Test the get_account_transactions function with the new balance column
	// t.Run(
	// 	"GetAccountTransactions", func(t *testing.T) {
	// 		t.Skip("Skipping until implementation is ready")
	// 	},
	// )
}
