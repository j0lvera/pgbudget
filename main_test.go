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

	// Test account creation and update via api.accounts view
	var accountUUID string // To be set by CreateAccount and used by UpdateAccount
	var accountID int      // Internal ID for data.accounts verification

	// --- Account Tests ---
	t.Run(
		"Accounts", func(t *testing.T) {
			t.Run(
				"CreateAccount", func(t *testing.T) {
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
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.accounts (ledger_uuid, name, type, description, metadata)
			 VALUES ($1, $2, $3, $4, $5)
			 RETURNING uuid, name, type, description, metadata, user_data, ledger_uuid`,
						ledgerUUID, accountName, accountType,
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
						retLedgerUUID, ledgerUUID,
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
						dbLedgerID, ledgerID,
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
		},
	)

	// --- Category Tests ---
	t.Run(
		"Categories", func(t *testing.T) {
			// This is the subtest for creating a category
			t.Run(
				"CreateCategory", func(t *testing.T) {
					// t.Skip("For now") // Removed/Commented

					// Skip if ledger creation failed
					if ledgerUUID == "" {
						t.Skip("Skipping CreateCategory tests because ledger creation failed or did not run")
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
								ctx, "SELECT api.add_category($1, $2)",
								ledgerUUID,
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
								ledgerUUID, "",
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
			// These UUIDs will be populated by sub-setup tests within "CreateTransaction"
			var transactionLedgerUUID string // This will be assigned ledgerUUID from the outer scope
			var mainAccountUUID string       // e.g., a checking account
			var expenseCategoryUUID string   // e.g., a "Shopping" category

			// Internal IDs for verification
			var mainAccountID int
			var expenseCategoryID int

			t.Run(
				"CreateTransaction", func(t *testing.T) {
					// Assign the ledgerUUID from the outer scope.
					// ledgerUUID and ledgerID are available from the "Ledgers" test group.
					transactionLedgerUUID = ledgerUUID
					if transactionLedgerUUID == "" {
						t.Skip("Skipping CreateTransaction tests because ledger UUID is not available")
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
								dbLedgerID, ledgerID,
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
								dbLedgerID, ledgerID,
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
							// The expected message from utils.simple_transactions_insert_fn is 'ledger with uuid % not found'
							is.True(
								strings.Contains(
									pgErr.Message, "ledger with uuid",
								),
							)
							is.True(
								strings.Contains(
									pgErr.Message, "not found",
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

	// --- Balances Tracking Tests ---
	t.Run(
		"BalancesTracking", func(t *testing.T) {
			// Create a new is instance for this test group
			is := is_.New(t)
			
			// Create a new ledger specifically for this test
			var balancesLedgerUUID string
			var balancesLedgerID int
			
			// Create a new ledger using the api.ledgers view
			ledgerName := "BalancesTracking Test Ledger"
			err := conn.QueryRow(
				ctx,
				"insert into api.ledgers (name) values ($1) returning uuid",
				ledgerName,
			).Scan(&balancesLedgerUUID)
			is.NoErr(err) // should create ledger without error
			
			// Get the internal ID for verification
			err = conn.QueryRow(
				ctx,
				"SELECT id FROM data.ledgers WHERE uuid = $1",
				balancesLedgerUUID,
			).Scan(&balancesLedgerID)
			is.NoErr(err) // should find the ledger by UUID
			is.True(balancesLedgerID > 0) // should have a valid internal ID

			var (
				btCheckingAccountUUID string
				btCheckingAccountID   int
				// btCheckingAccountIntType   string // Not directly used, but good for context
				btGroceriesCategoryUUID string
				btGroceriesCategoryID   int
				// btGroceriesCategoryIntType string // Not directly used
			)

			// Helper to get latest balance details directly from data.balances
			// It now takes t *testing.T to create a subtest-specific 'is' instance.
			getLatestBalanceEntry := func(
				subTestT *testing.T, accountID int,
			) (prevBal int64, currentBal int64, opType string, found bool) {
				is := is_.New(subTestT) // Create 'is' instance specific to this helper call's context
				err := conn.QueryRow(
					ctx,
					`SELECT previous_balance, balance, operation_type FROM data.balances
				 WHERE account_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1`,
					accountID,
				).Scan(&prevBal, &currentBal, &opType)
				if errors.Is(err, pgx.ErrNoRows) {
					return 0, 0, "", false
				}
				is.NoErr(err)
				return prevBal, currentBal, opType, true
			}

			// Setup: Create dedicated accounts for balance tracking tests
			t.Run(
				"Setup_BalanceTestAccounts", func(t *testing.T) {
					is := is_.New(t)
					var checkingIntType, groceriesIntType string // Temporary for setup verification

					// 1. Create Checking Account (Asset)
					checkingName := "BT Checking"
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, 'asset') RETURNING uuid`,
						balancesLedgerUUID, checkingName,
					).Scan(&btCheckingAccountUUID)
					is.NoErr(err)
					is.True(btCheckingAccountUUID != "")

					err = conn.QueryRow(
						ctx,
						`SELECT id, internal_type FROM data.accounts WHERE uuid = $1`,
						btCheckingAccountUUID,
					).Scan(&btCheckingAccountID, &checkingIntType)
					is.NoErr(err)
					is.True(btCheckingAccountID > 0)
					is.Equal(checkingIntType, "asset_like")
					// btCheckingAccountIntType = checkingIntType // Store if needed elsewhere

					// 2. Create Groceries Category (Equity)
					groceriesName := "BT Groceries"
					err = conn.QueryRow(
						ctx,
						`SELECT uuid FROM api.add_category($1, $2)`,
						balancesLedgerUUID, groceriesName,
					).Scan(&btGroceriesCategoryUUID)
					is.NoErr(err)
					is.True(btGroceriesCategoryUUID != "")

					err = conn.QueryRow(
						ctx,
						`SELECT id, internal_type FROM data.accounts WHERE uuid = $1`,
						btGroceriesCategoryUUID,
					).Scan(&btGroceriesCategoryID, &groceriesIntType)
					is.NoErr(err)
					is.True(btGroceriesCategoryID > 0)
					is.Equal(groceriesIntType, "liability_like")
					// btGroceriesCategoryIntType = groceriesIntType // Store if needed elsewhere

					// 3. Fetch Income Category UUID and ID for this ledger
					var btIncomeCategoryUUID string
					var btIncomeCategoryID int // Not strictly needed for these inserts but good for completeness

					err = conn.QueryRow(
						ctx,
						"SELECT utils.find_category($1, $2)", // find_category directly returns the UUID
						balancesLedgerUUID, "Income",
					).Scan(&btIncomeCategoryUUID)
					is.NoErr(err) // Should find the Income category for the ledger
					is.True(btIncomeCategoryUUID != "")

					// Optionally, get internal ID if needed for other checks, though not used in inserts below
					err = conn.QueryRow(
						ctx,
						"SELECT id FROM data.accounts WHERE uuid = $1",
						btIncomeCategoryUUID,
					).Scan(&btIncomeCategoryID)
					is.NoErr(err)
					is.True(btIncomeCategoryID > 0)

					// 4. Add Income Transaction to BT Checking, categorized as Income
					initialIncomeAmount := int64(100000) // $1000.00
					incomeDesc := "BT Initial Income Deposit"
					incomeDate := time.Now().Add(-2 * time.Minute) // Ensure this is before budget allocation
					var incomeTxUUID string

					// Insert via api.transactions: type 'inflow', account_uuid is checking, category_uuid is Income
					// This should debit Checking (Asset +) and credit Income (Equity +)
					err = conn.QueryRow(
						ctx,
						`INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
				 VALUES ($1, $2, $3, 'inflow', $4, $5, $6) RETURNING uuid`,
						balancesLedgerUUID, incomeDate, incomeDesc, initialIncomeAmount,
						btCheckingAccountUUID, btIncomeCategoryUUID,
					).Scan(&incomeTxUUID)
					is.NoErr(err) // Should create income transaction
					is.True(incomeTxUUID != "")

					// 5. Assign Money from Income to BT Groceries Category
					budgetAllocationAmount := int64(20000) // $200.00
					budgetAllocationDesc := "BT Budget Allocation for Groceries"
					budgetAllocationDate := time.Now().Add(-1 * time.Minute) // After income, before spending
					var budgetTxUUID string

					// This function debits Income category and credits the target category (BT Groceries)
					err = conn.QueryRow(
						ctx,
						"SELECT uuid FROM api.assign_to_category($1, $2, $3, $4, $5)",
						balancesLedgerUUID, budgetAllocationDate, budgetAllocationDesc,
						budgetAllocationAmount, btGroceriesCategoryUUID,
					).Scan(&budgetTxUUID)
					is.NoErr(err) // Should assign money to category
					is.True(budgetTxUUID != "")
				},
			)

			if btCheckingAccountUUID == "" || btGroceriesCategoryUUID == "" {
				// Use t.Fatalf for setup failures to stop further tests in this group.
				t.Fatalf(
					"Failed to set up accounts for BalancesTracking tests. CheckingUUID: '%s', GroceriesUUID: '%s'",
					btCheckingAccountUUID, btGroceriesCategoryUUID,
				)
			}

			var outflowTxUUID string
			var outflowTxInternalID int      // Store as int
			var outflowTxAmount int64 = 7500 // $75.00

			t.Run(
				"Insert_OutflowTransaction", func(t *testing.T) {
					is := is_.New(t)
					txTime := time.Now()

					// Expected balances after setup transactions
					// BT Checking received initialIncomeAmount.
					// BT Groceries received budgetAllocationAmount from Income.
					expectedCheckingBalanceAfterSetup := int64(100000) // Matches initialIncomeAmount from setup
					expectedGroceriesBalanceAfterSetup := int64(20000) // Matches budgetAllocationAmount from setup

					// Get current balances (these are the "initial" balances for this outflow test)
					// Note: getLatestBalanceEntry returns (prevBal, currentBal, opType, found)
					// We are interested in currentBal here.
					_, initialCheckingBal, _, checkingFound := getLatestBalanceEntry(
						t, btCheckingAccountID,
					)
					is.True(checkingFound) // Expect balance entry to exist now due to setup transactions
					is.Equal(
						initialCheckingBal, expectedCheckingBalanceAfterSetup,
					)

					_, initialGroceriesBal, _, groceriesFound := getLatestBalanceEntry(
						t, btGroceriesCategoryID,
					)
					is.True(groceriesFound) // Expect balance entry to exist now due to setup transactions
					is.Equal(
						initialGroceriesBal, expectedGroceriesBalanceAfterSetup,
					)

					// Insert outflow transaction: Spend from Checking for Groceries
					// api.transactions: account_uuid is Checking, category_uuid is Groceries, type is outflow
					// data.transactions: debit=Groceries(L), credit=Checking(A)
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
				 VALUES ($1, $2, $3, 'outflow', $4, 'BT Outflow', $5) RETURNING uuid`,
						balancesLedgerUUID, btCheckingAccountUUID,
						btGroceriesCategoryUUID, outflowTxAmount, txTime,
					).Scan(&outflowTxUUID)
					is.NoErr(err)
					is.True(outflowTxUUID != "")

					// Get internal transaction ID
					err = conn.QueryRow(
						ctx, "SELECT id FROM data.transactions WHERE uuid = $1",
						outflowTxUUID,
					).Scan(&outflowTxInternalID)
					is.NoErr(err)
					is.True(outflowTxInternalID > 0)

					// Verify data.balances entries
					var balanceEntries []struct {
						AccountID       int
						PreviousBalance int64
						Delta           int64
						Balance         int64
						OperationType   string
						UserData        string
					}
					rows, err := conn.Query(
						ctx,
						`SELECT account_id, previous_balance, delta, balance, operation_type, user_data
				 FROM data.balances WHERE transaction_id = $1 ORDER BY account_id`, // Order by account_id for predictable checking
						outflowTxInternalID,
					)
					is.NoErr(err)
					defer rows.Close()
					for rows.Next() {
						var entry struct {
							AccountID       int
							PreviousBalance int64
							Delta           int64
							Balance         int64
							OperationType   string
							UserData        string
						}
						err = rows.Scan(
							&entry.AccountID, &entry.PreviousBalance,
							&entry.Delta, &entry.Balance, &entry.OperationType,
							&entry.UserData,
						)
						is.NoErr(err)
						balanceEntries = append(balanceEntries, entry)
					}
					is.NoErr(rows.Err())
					is.Equal(
						len(balanceEntries), 2,
					) // Should have two balance entries

					for _, entry := range balanceEntries {
						is.Equal(entry.OperationType, "transaction_insert")
						is.Equal(entry.UserData, testUserID)
						if entry.AccountID == btCheckingAccountID { // Checking (Asset, credited by outflow)
							is.Equal(entry.PreviousBalance, initialCheckingBal)
							is.Equal(
								entry.Delta, -outflowTxAmount,
							) // Credit to asset_like decreases balance
							is.Equal(
								entry.Balance,
								initialCheckingBal-outflowTxAmount,
							)
						} else if entry.AccountID == btGroceriesCategoryID { // Groceries (Equity/Liability-like, debited by outflow)
							is.Equal(entry.PreviousBalance, initialGroceriesBal)
							is.Equal(
								entry.Delta, -outflowTxAmount,
							) // Debit to liability_like decreases balance
							is.Equal(
								entry.Balance,
								initialGroceriesBal-outflowTxAmount,
							)
						} else {
							t.Fatalf(
								"Unexpected account_id in balance entry: %d",
								entry.AccountID,
							)
						}
					}

					// Verify api.balances view
					var apiBalanceEntries []struct {
						AccountUUID string
						Balance     int64
						Delta       int64
					}
					rowsAPI, err := conn.Query(
						ctx,
						`SELECT account_uuid, balance, delta FROM api.balances WHERE transaction_uuid = $1 ORDER BY account_uuid`,
						outflowTxUUID,
					)
					is.NoErr(err)
					defer rowsAPI.Close()
					for rowsAPI.Next() {
						var entry struct {
							AccountUUID string
							Balance     int64
							Delta       int64
						}
						err = rowsAPI.Scan(
							&entry.AccountUUID, &entry.Balance, &entry.Delta,
						)
						is.NoErr(err)
						apiBalanceEntries = append(apiBalanceEntries, entry)
					}
					is.NoErr(rowsAPI.Err())
					is.Equal(len(apiBalanceEntries), 2)

					for _, entry := range apiBalanceEntries {
						if entry.AccountUUID == btCheckingAccountUUID {
							is.Equal(entry.Delta, -outflowTxAmount)
							is.Equal(
								entry.Balance,
								initialCheckingBal-outflowTxAmount,
							)
						} else if entry.AccountUUID == btGroceriesCategoryUUID {
							is.Equal(entry.Delta, -outflowTxAmount)
							is.Equal(
								entry.Balance,
								initialGroceriesBal-outflowTxAmount,
							)
						} else {
							t.Fatalf(
								"Unexpected account_uuid in API balance entry: %s",
								entry.AccountUUID,
							)
						}
					}
				},
			)

			var inflowTxUUID string
			var inflowTxInternalID int
			var inflowTxAmount int64 = 30000 // $300.00 (changed from 3000 to make it different from outflow)

			t.Run(
				"Insert_InflowTransaction", func(t *testing.T) {
					is := is_.New(t)
					txTime := time.Now().Add(1 * time.Second)

					// Get current balances after the outflow
					_, prevCheckingBal, _, checkingFound := getLatestBalanceEntry(
						t, btCheckingAccountID,
					)
					is.True(checkingFound) // Should exist now
					_, prevGroceriesBal, _, groceriesFound := getLatestBalanceEntry(
						t, btGroceriesCategoryID,
					)
					is.True(groceriesFound) // Should exist now

					// Insert inflow transaction: Income to Checking, sourced from Groceries category for this test
					// api.transactions: account_uuid is Checking, category_uuid is Groceries, type is inflow
					// data.transactions: debit=Checking(A), credit=Groceries(L)
					err := conn.QueryRow(
						ctx,
						`INSERT INTO api.transactions (ledger_uuid, account_uuid, category_uuid, type, amount, description, date)
				 VALUES ($1, $2, $3, 'inflow', $4, 'BT Inflow', $5) RETURNING uuid`,
						balancesLedgerUUID, btCheckingAccountUUID,
						btGroceriesCategoryUUID, inflowTxAmount, txTime,
					).Scan(&inflowTxUUID)
					is.NoErr(err)
					is.True(inflowTxUUID != "")

					err = conn.QueryRow(
						ctx, "SELECT id FROM data.transactions WHERE uuid = $1",
						inflowTxUUID,
					).Scan(&inflowTxInternalID)
					is.NoErr(err)
					is.True(inflowTxInternalID > 0)

					// Verify data.balances entries
					var balanceEntries []struct {
						AccountID       int
						PreviousBalance int64
						Delta           int64
						Balance         int64
						OperationType   string
					}
					rows, err := conn.Query(
						ctx,
						`SELECT account_id, previous_balance, delta, balance, operation_type
				 FROM data.balances WHERE transaction_id = $1 ORDER BY account_id`,
						inflowTxInternalID,
					)
					is.NoErr(err)
					defer rows.Close()
					for rows.Next() {
						var entry struct {
							AccountID       int
							PreviousBalance int64
							Delta           int64
							Balance         int64
							OperationType   string
						}
						err = rows.Scan(
							&entry.AccountID, &entry.PreviousBalance,
							&entry.Delta, &entry.Balance, &entry.OperationType,
						)
						is.NoErr(err)
						balanceEntries = append(balanceEntries, entry)
					}
					is.NoErr(rows.Err())
					is.Equal(len(balanceEntries), 2)

					for _, entry := range balanceEntries {
						is.Equal(entry.OperationType, "transaction_insert")
						if entry.AccountID == btCheckingAccountID { // Checking (Asset, debited by inflow)
							is.Equal(entry.PreviousBalance, prevCheckingBal)
							is.Equal(
								entry.Delta, inflowTxAmount,
							) // Debit to asset_like increases balance
							is.Equal(
								entry.Balance, prevCheckingBal+inflowTxAmount,
							)
						} else if entry.AccountID == btGroceriesCategoryID { // Groceries (Equity/Liability-like, credited by inflow)
							is.Equal(entry.PreviousBalance, prevGroceriesBal)
							is.Equal(
								entry.Delta, inflowTxAmount,
							) // Credit to liability_like increases balance
							is.Equal(
								entry.Balance, prevGroceriesBal+inflowTxAmount,
							)
						} else {
							t.Fatalf(
								"Unexpected account_id: %d", entry.AccountID,
							)
						}
					}
				},
			)

			t.Run(
				"Update_TransactionAmount", func(t *testing.T) {
					is := is_.New(t)
					if outflowTxUUID == "" || outflowTxInternalID == 0 {
						t.Skip("Skipping Update_TransactionAmount as outflowTxUUID/ID is not set")
					}

					newOutflowTxAmount := int64(10000) // $100.00, original was $75.00 (outflowTxAmount)

					// Get balances before update for each account involved in outflowTx
					// These are the balances *after* the inflow transaction, but *before* this update.
					_, prevCheckingBalBeforeUpdate, _, checkingFound := getLatestBalanceEntry(
						t, btCheckingAccountID,
					)
					is.True(checkingFound)
					_, prevGroceriesBalBeforeUpdate, _, groceriesFound := getLatestBalanceEntry(
						t, btGroceriesCategoryID,
					)
					is.True(groceriesFound)

					// Update the amount of the first outflow transaction
					var updatedAmount int64
					err := conn.QueryRow(
						ctx,
						`UPDATE api.transactions SET amount = $1 WHERE uuid = $2 RETURNING amount`,
						newOutflowTxAmount, outflowTxUUID,
					).Scan(&updatedAmount)
					is.NoErr(err)
					is.Equal(updatedAmount, newOutflowTxAmount)

					// Verify data.balances entries for this transaction_id
					var updateBalanceEntries []struct {
						AccountID       int
						PreviousBalance int64
						Delta           int64
						Balance         int64
						OperationType   string
					}
					rows, err := conn.Query(
						ctx,
						`SELECT account_id, previous_balance, delta, balance, operation_type
				 FROM data.balances WHERE transaction_id = $1 AND operation_type LIKE 'transaction_update_%'
				 ORDER BY created_at ASC, id ASC`, // Order by creation to see reversal then application
						outflowTxInternalID,
					)
					is.NoErr(err)
					defer rows.Close()
					for rows.Next() {
						var entry struct {
							AccountID       int
							PreviousBalance int64
							Delta           int64
							Balance         int64
							OperationType   string
						}
						err = rows.Scan(
							&entry.AccountID, &entry.PreviousBalance,
							&entry.Delta, &entry.Balance, &entry.OperationType,
						)
						is.NoErr(err)
						updateBalanceEntries = append(
							updateBalanceEntries, entry,
						)
					}
					is.NoErr(rows.Err())
					is.Equal(
						len(updateBalanceEntries), 4,
					) // 2 reversal, 2 application

					// Verify Reversal Entries (original outflowTxAmount = $75.00)
					// Original outflow: Debit Groceries(L), Credit Checking(A).
					// For Groceries (liability-like): Debit decreases balance, so delta was -7500
					// For Checking (asset-like): Credit decreases balance, so delta was -7500
					// Reversal deltas should be +7500 for both (opposite of original).
					is.Equal(
						updateBalanceEntries[0].OperationType,
						"transaction_update_reversal",
					)
					is.Equal(
						updateBalanceEntries[1].OperationType,
						"transaction_update_reversal",
					)

					var checkingReversalDone, groceriesReversalDone bool
					for i := 0; i < 2; i++ { // Check first two entries for reversal
						entry := updateBalanceEntries[i]
						if entry.AccountID == btCheckingAccountID {
							is.Equal(
								entry.PreviousBalance,
								prevCheckingBalBeforeUpdate,
							)
							is.Equal(
								entry.Delta, outflowTxAmount,
							) // Reversing original delta of -outflowTxAmount by adding the amount
							is.Equal(
								entry.Balance,
								prevCheckingBalBeforeUpdate+outflowTxAmount,
							)
							checkingReversalDone = true
						} else if entry.AccountID == btGroceriesCategoryID {
							is.Equal(
								entry.PreviousBalance,
								prevGroceriesBalBeforeUpdate,
							)
							is.Equal(
								entry.Delta, outflowTxAmount,
							) // Reversing original delta of -outflowTxAmount by adding the amount
							is.Equal(
								entry.Balance,
								prevGroceriesBalBeforeUpdate+outflowTxAmount,
							)
							groceriesReversalDone = true
						} else {
							t.Fatalf(
								"Unexpected account_id %d in reversal balance entry",
								entry.AccountID,
							)
						}
					}
					is.True(checkingReversalDone)  // Checking account reversal missing or incorrect
					is.True(groceriesReversalDone) // Groceries account reversal missing or incorrect

					// Balances after reversal
					balanceCheckingAfterReversal := prevCheckingBalBeforeUpdate + outflowTxAmount
					balanceGroceriesAfterReversal := prevGroceriesBalBeforeUpdate + outflowTxAmount

					// Verify Application Entries (newOutflowTxAmount = $100.00)
					// New outflow: Debit Groceries(L), Credit Checking(A).
					// For Groceries (liability-like): Debit decreases balance, so delta should be -10000
					// For Checking (asset-like): Credit decreases balance, so delta should be -10000
					is.Equal(
						updateBalanceEntries[2].OperationType,
						"transaction_update_application",
					)
					is.Equal(
						updateBalanceEntries[3].OperationType,
						"transaction_update_application",
					)

					var checkingApplicationDone, groceriesApplicationDone bool
					for i := 2; i < 4; i++ { // Check next two entries for application
						entry := updateBalanceEntries[i]
						if entry.AccountID == btCheckingAccountID { // Checking (Asset, credited)
							is.Equal(
								entry.PreviousBalance,
								balanceCheckingAfterReversal,
							)
							is.Equal(entry.Delta, -newOutflowTxAmount)
							is.Equal(
								entry.Balance,
								balanceCheckingAfterReversal-newOutflowTxAmount,
							)
							checkingApplicationDone = true
						} else if entry.AccountID == btGroceriesCategoryID { // Groceries (Equity/L, debited)
							is.Equal(
								entry.PreviousBalance,
								balanceGroceriesAfterReversal,
							)
							is.Equal(entry.Delta, -newOutflowTxAmount)
							is.Equal(
								entry.Balance,
								balanceGroceriesAfterReversal-newOutflowTxAmount,
							)
							groceriesApplicationDone = true
						} else {
							t.Fatalf(
								"Unexpected account_id %d in application balance entry",
								entry.AccountID,
							)
						}
					}
					is.True(checkingApplicationDone)  // Checking account application missing or incorrect
					is.True(groceriesApplicationDone) // Groceries account application missing or incorrect
				},
			)

			t.Run(
				"Delete_Transaction_SoftDelete", func(t *testing.T) {
					is := is_.New(t)
					if inflowTxUUID == "" || inflowTxInternalID == 0 {
						t.Skip("Skipping Delete_Transaction_SoftDelete as inflowTxUUID/ID is not set")
					}

					// Get balances before delete for accounts involved in inflowTx
					// These are the balances *after* the outflow update, but *before* this delete.
					_, prevCheckingBalBeforeDelete, _, checkingFound := getLatestBalanceEntry(
						t, btCheckingAccountID,
					)
					is.True(checkingFound)
					_, prevGroceriesBalBeforeDelete, _, groceriesFound := getLatestBalanceEntry(
						t, btGroceriesCategoryID,
					)
					is.True(groceriesFound)

					// Delete the inflow transaction (original inflowTxAmount = $300.00)
					// Original inflow: Debit Checking(A), Credit Groceries(L). Deltas were +30000 for both.
					// Deletion deltas should be -30000 for both.
					_, err := conn.Exec(
						ctx, `DELETE FROM api.transactions WHERE uuid = $1`,
						inflowTxUUID,
					)
					is.NoErr(err)

					// 1. Verify data.transactions.deleted_at is set
					var deletedAt pgtype.Timestamptz
					err = conn.QueryRow(
						ctx,
						"SELECT deleted_at FROM data.transactions WHERE uuid = $1",
						inflowTxUUID,
					).Scan(&deletedAt)
					is.NoErr(err)                     // Should find the transaction in data.transactions
					is.True(deletedAt.Valid)          // deleted_at should be set (not NULL)
					is.True(!deletedAt.Time.IsZero()) // deleted_at should be a valid timestamp

					// 2. Verify transaction is not visible in api.transactions view
					// (Assuming api.transactions view is updated to filter out deleted_at IS NOT NULL)
					var tempUUID string
					err = conn.QueryRow(
						ctx,
						"SELECT uuid FROM api.transactions WHERE uuid = $1",
						inflowTxUUID,
					).Scan(&tempUUID)
					is.True(
						errors.Is(
							err, pgx.ErrNoRows,
						),
					) // Should not find transaction in API view

					// 3. Verify original data.balances entries for 'transaction_insert' still exist
					var originalInsertCount int
					err = conn.QueryRow(
						ctx,
						"SELECT COUNT(*) FROM data.balances WHERE transaction_id = $1 AND operation_type = 'transaction_insert'",
						inflowTxInternalID,
					).Scan(&originalInsertCount)
					is.NoErr(err)
					is.Equal(
						originalInsertCount, 2,
					) // The two original insert balance entries should still be there

					// 4. Verify new data.balances entries for 'transaction_soft_delete'
					var deleteBalanceEntries []struct {
						AccountID       int
						PreviousBalance int64
						Delta           int64
						Balance         int64
						OperationType   string
					}
					rows, err := conn.Query(
						ctx,
						`SELECT account_id, previous_balance, delta, balance, operation_type
				 FROM data.balances WHERE transaction_id = $1 AND operation_type = 'transaction_soft_delete'
				 ORDER BY account_id ASC`, // Order by account_id for predictable checking
						inflowTxInternalID,
					)
					is.NoErr(err)
					defer rows.Close()
					for rows.Next() {
						var entry struct {
							AccountID       int
							PreviousBalance int64
							Delta           int64
							Balance         int64
							OperationType   string
						}
						err = rows.Scan(
							&entry.AccountID, &entry.PreviousBalance,
							&entry.Delta, &entry.Balance, &entry.OperationType,
						)
						is.NoErr(err)
						deleteBalanceEntries = append(
							deleteBalanceEntries, entry,
						)
					}
					is.NoErr(rows.Err())
					is.Equal(len(deleteBalanceEntries), 2)

					var checkingDeleteDone, groceriesDeleteDone bool
					for _, entry := range deleteBalanceEntries {
						is.Equal(entry.OperationType, "transaction_soft_delete")
						if entry.AccountID == btCheckingAccountID { // Checking (Asset)
							is.Equal(
								entry.PreviousBalance,
								prevCheckingBalBeforeDelete,
							)
							is.Equal(
								entry.Delta, -inflowTxAmount,
							) // Reversing original delta of +inflowTxAmount
							is.Equal(
								entry.Balance,
								prevCheckingBalBeforeDelete-inflowTxAmount,
							)
							checkingDeleteDone = true
						} else if entry.AccountID == btGroceriesCategoryID { // Groceries (Equity/L)
							is.Equal(
								entry.PreviousBalance,
								prevGroceriesBalBeforeDelete,
							)
							is.Equal(
								entry.Delta, -inflowTxAmount,
							) // Reversing original delta of +inflowTxAmount
							is.Equal(
								entry.Balance,
								prevGroceriesBalBeforeDelete-inflowTxAmount,
							)
							groceriesDeleteDone = true
						} else {
							t.Fatalf(
								"Unexpected account_id %d in delete balance entry",
								entry.AccountID,
							)
						}
					}
					is.True(checkingDeleteDone)  // Checking account delete missing or incorrect
					is.True(groceriesDeleteDone) // Groceries account delete missing or incorrect
				},
			)

		},
	) // End of BalancesTracking

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
	// 	"BalancesTracking", func(t *testing.T) { // This is the one being added
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
