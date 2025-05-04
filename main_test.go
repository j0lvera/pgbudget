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
// Returns the ledger ID and a map of account IDs by name for easy reference
// NOTE: This function uses older API calls (returning int IDs) and needs updating
// if those functions are removed or changed to return UUIDs/records.
func setupTestLedger(
	ctx context.Context, conn *pgx.Conn, ledgerName string,
) (int, map[string]int, map[string]int, error) {
	// Create a new ledger
	var ledgerID int
	var ledgerUUID string // Need UUID to get ID
	err := conn.QueryRow(
		ctx,
		// Insert into the view, not the base table, to simulate API usage
		"INSERT INTO api.ledgers (name) VALUES ($1) RETURNING uuid",
		ledgerName,
	).Scan(&ledgerUUID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to create ledger via API view: %w", err)
	}

	// Fetch the internal ID using the returned UUID
	err = conn.QueryRow(
		ctx,
		"SELECT id FROM data.ledgers WHERE uuid = $1",
		ledgerUUID,
	).Scan(&ledgerID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to get ledger ID from UUID: %w", err)
	}


	// Map to store account IDs by name
	accounts := make(map[string]int)
	transactions := make(map[string]int)

	// Create checking account using api.add_account
	// TODO: Update if api.add_account changes signature (it likely will need to use UUIDs)
	// For now, assume it still returns an int ID for setup purposes
	var checkingID int
	var checkingUUID string // Assume we'll need UUID later
	// Hypothetical future call using UUIDs:
	// err = conn.QueryRow(ctx, "SELECT uuid FROM api.add_account($1, $2, $3)", ledgerUUID, "Checking", "asset").Scan(&checkingUUID)
	// For now, stick to the old signature if it exists, otherwise this setup needs a rewrite
	err = conn.QueryRow(
		ctx,
		"SELECT id FROM api.add_account($1, $2, $3)", // Assuming old signature still exists for setup
		ledgerID, "Checking", "asset",
	).Scan(&checkingID)
	if err != nil {
		// If the old signature is gone, this will fail.
		// We might need to insert directly into data.accounts or use the new view/trigger
		// For now, let's try inserting via the view if the function fails
		log.Warn().Err(err).Msg("api.add_account(int) failed, trying insert into api.accounts view")
		errInsert := conn.QueryRow(ctx,
			`INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ($1, $2, $3) RETURNING uuid`,
			ledgerUUID, "Checking", "asset",
		).Scan(&checkingUUID)
		if errInsert != nil {
			return 0, nil, nil, fmt.Errorf("failed to create checking account via function or view insert: %w / %w", err, errInsert)
		}
		// Get the internal ID from the UUID
		errId := conn.QueryRow(ctx, "SELECT id FROM data.accounts WHERE uuid = $1", checkingUUID).Scan(&checkingID)
		if errId != nil {
			return 0, nil, nil, fmt.Errorf("failed to get checking account ID from UUID after view insert: %w", errId)
		}
	}
	accounts["Checking"] = checkingID


	// Create groceries category using api.add_category
	var groceriesID int
	var groceriesUUID string // We need the UUID now
	err = conn.QueryRow(
		ctx,
		"SELECT uuid FROM api.add_category($1, $2)", // Call new function
		ledgerUUID, "Groceries", // Use ledger UUID
	).Scan(&groceriesUUID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create groceries category: %w", err,
		)
	}
	// Fetch the ID from the UUID for internal use in this setup function
	err = conn.QueryRow(ctx, "SELECT id FROM data.accounts WHERE uuid = $1", groceriesUUID).Scan(&groceriesID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to get groceries ID from UUID: %w", err)
	}
	accounts["Groceries"] = groceriesID


	// Find the Income account (should be created automatically with the ledger)
	var incomeUUID string
	err = conn.QueryRow(
		ctx,
		"SELECT utils.find_category($1, $2)", // Use utils function
		ledgerUUID, "Income", // Use ledger UUID
	).Scan(&incomeUUID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to find income category UUID: %w", err,
		)
	}
	// Fetch the ID from the UUID for internal use in this setup function
	var incomeID int
	err = conn.QueryRow(ctx, "SELECT id FROM data.accounts WHERE uuid = $1", incomeUUID).Scan(&incomeID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to get income ID from UUID: %w", err)
	}
	accounts["Income"] = incomeID


	// 1. Create a transaction to simulate receiving income
	// TODO: Update if api.add_transaction changes signature (it likely will need to use UUIDs)
	// For now, assume it still returns an int ID for setup purposes
	var incomeTxID int
	var incomeTxUUID string // Assume we'll need UUID later
	// Hypothetical future call using UUIDs:
	// err = conn.QueryRow(ctx, "INSERT INTO api.simple_transactions (...) VALUES (...) RETURNING uuid").Scan(&incomeTxUUID)
	// For now, stick to the old signature if it exists, otherwise this setup needs a rewrite
	err = conn.QueryRow(
		ctx,
		"SELECT id FROM api.add_transaction($1, $2, $3, $4, $5, $6, $7)", // Assuming old signature
		ledgerID, "2023-01-01", "Salary deposit", "inflow",
		100000, // $1000.00
		checkingID, incomeID,
	).Scan(&incomeTxID)
	if err != nil {
		// If the old signature is gone, this will fail.
		// We might need to insert directly into api.simple_transactions
		log.Warn().Err(err).Msg("api.add_transaction(int) failed, trying insert into api.simple_transactions view")
		// Need checking account UUID and income category UUID
		var checkingAccUUID, incomeCatUUID string
		errCA := conn.QueryRow(ctx, "SELECT uuid FROM data.accounts WHERE id = $1", checkingID).Scan(&checkingAccUUID)
		if errCA != nil { return 0, nil, nil, fmt.Errorf("failed to get checking UUID for simple_tx: %w", errCA) }
		errIC := conn.QueryRow(ctx, "SELECT uuid FROM data.accounts WHERE id = $1", incomeID).Scan(&incomeCatUUID)
		if errIC != nil { return 0, nil, nil, fmt.Errorf("failed to get income UUID for simple_tx: %w", errIC) }

		errInsert := conn.QueryRow(ctx,
			`INSERT INTO api.simple_transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`,
			ledgerUUID, "2023-01-01", "Salary deposit", "inflow", 100000, checkingAccUUID, incomeCatUUID,
		).Scan(&incomeTxUUID)
		if errInsert != nil {
			return 0, nil, nil, fmt.Errorf("failed to create income transaction via function or simple_transactions view: %w / %w", err, errInsert)
		}
		// Get the internal ID from the UUID
		errId := conn.QueryRow(ctx, "SELECT id FROM data.transactions WHERE uuid = $1", incomeTxUUID).Scan(&incomeTxID)
		if errId != nil {
			return 0, nil, nil, fmt.Errorf("failed to get income tx ID from UUID after view insert: %w", errId)
		}
	}
	transactions["Income"] = incomeTxID


	// 2. Create a transaction to budget money from Income to Groceries
	var budgetTxUUID string
	err = conn.QueryRow(
		ctx,
		"SELECT uuid FROM api.assign_to_category($1, $2, $3, $4, $5)", // Call new function
		ledgerUUID, "2023-01-01", "Budget allocation to Groceries",
		30000, // $300.00
		groceriesUUID, // Use category UUID
	).Scan(&budgetTxUUID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create budget transaction: %w", err,
		)
	}
	// Fetch the ID from the UUID for internal use in this setup function
	var budgetTxID int
	err = conn.QueryRow(ctx, "SELECT id FROM data.transactions WHERE uuid = $1", budgetTxUUID).Scan(&budgetTxID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to get budget tx ID from UUID: %w", err)
	}
	transactions["Budget"] = budgetTxID


	// 3. Create a transaction to spend from Groceries
	// TODO: Update if api.add_transaction changes signature (it likely will need to use UUIDs)
	var spendTxID int
	var spendTxUUID string // Assume we'll need UUID later
	// Hypothetical future call using UUIDs:
	// err = conn.QueryRow(ctx, "INSERT INTO api.simple_transactions (...) VALUES (...) RETURNING uuid").Scan(&spendTxUUID)
	// For now, stick to the old signature if it exists, otherwise this setup needs a rewrite
	err = conn.QueryRow(
		ctx,
		"SELECT id FROM api.add_transaction($1, $2, $3, $4, $5, $6, $7)", // Assuming old signature
		ledgerID, "2023-01-02", "Grocery shopping", "outflow",
		7500, // $75.00
		checkingID, groceriesID,
	).Scan(&spendTxID)
	if err != nil {
		// If the old signature is gone, this will fail.
		// We might need to insert directly into api.simple_transactions
		log.Warn().Err(err).Msg("api.add_transaction(int) failed, trying insert into api.simple_transactions view")
		// Need checking account UUID and groceries category UUID
		var checkingAccUUID, groceriesCatUUID string
		errCA := conn.QueryRow(ctx, "SELECT uuid FROM data.accounts WHERE id = $1", checkingID).Scan(&checkingAccUUID)
		if errCA != nil { return 0, nil, nil, fmt.Errorf("failed to get checking UUID for simple_tx: %w", errCA) }
		errGC := conn.QueryRow(ctx, "SELECT uuid FROM data.accounts WHERE id = $1", groceriesID).Scan(&groceriesCatUUID)
		if errGC != nil { return 0, nil, nil, fmt.Errorf("failed to get groceries UUID for simple_tx: %w", errGC) }

		errInsert := conn.QueryRow(ctx,
			`INSERT INTO api.simple_transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uuid`,
			ledgerUUID, "2023-01-02", "Grocery shopping", "outflow", 7500, checkingAccUUID, groceriesCatUUID,
		).Scan(&spendTxUUID)
		if errInsert != nil {
			return 0, nil, nil, fmt.Errorf("failed to create spending transaction via function or simple_transactions view: %w / %w", err, errInsert)
		}
		// Get the internal ID from the UUID
		errId := conn.QueryRow(ctx, "SELECT id FROM data.transactions WHERE uuid = $1", spendTxUUID).Scan(&spendTxID)
		if errId != nil {
			return 0, nil, nil, fmt.Errorf("failed to get spending tx ID from UUID after view insert: %w", errId)
		}
	}
	transactions["Spend"] = spendTxID

	return ledgerID, accounts, transactions, nil
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
	jwtClaims := fmt.Sprintf(`{"role": "test_user", "email": "test@example.com", "user_data": "%s"}`, testUserID)
	// Use 'false' for session-local setting
	_, err = conn.Exec(ctx, `SELECT set_config('request.jwt.claims', $1, false)`, jwtClaims)
	is.NoErr(err) // Should set config without error

	// --- VERIFICATION STEPS ---
	// 1. Verify the setting was applied and is readable (session-local)
	var readClaims string
	// Use 'false' for session-local setting
	err = conn.QueryRow(ctx, `SELECT current_setting('request.jwt.claims', false)`).Scan(&readClaims)
	is.NoErr(err) // Should be able to read the setting back
	is.Equal(readClaims, jwtClaims) // Setting read back should match what was set

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
	var ledgerID int
	var ledgerUUID string // Add variable for UUID

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
			).Scan(&ledgerUUID) // Scan into ledgerUUID
			is.NoErr(err)             // Should create ledger without error
			is.True(ledgerUUID != "") // Should return a valid ledger UUID

			// Fetch the internal ID using the returned UUID
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

	// Test api.add_category function
	t.Run("AddCategory", func(t *testing.T) {
		// Skip if ledger creation failed
		if ledgerUUID == "" {
			t.Skip("Skipping AddCategory tests because ledger creation failed or did not run")
		}

		categoryName := "Groceries"
		var categoryUUID string // Store UUID for subsequent subtests

		// 1. Call api.add_category (Success Case)
		t.Run("Success", func(t *testing.T) {
			is := is_.New(t) // is instance for this subtest
			var (
				retUUID        string
				retName        string
				retType        string
				retDescription pgtype.Text
				retMetadata    pgtype.Map // Use pgtype.Map for jsonb
				retUserData    string
				retLedgerUUID  string
			)

			// Call the function and scan all returned fields
			err := conn.QueryRow(ctx, "SELECT * FROM api.add_category($1, $2)", ledgerUUID, categoryName).Scan(
				&retUUID,
				&retName,
				&retType,
				&retDescription,
				&retMetadata,
				&retUserData,
				&retLedgerUUID,
			)
			is.NoErr(err) // Should execute function without error

			// Assert Return Values
			is.True(retUUID != "")             // Should return a non-empty UUID
			is.Equal(retName, categoryName)    // Returned name should match input
			is.Equal(retType, "equity")        // Returned type should be 'equity'
			is.Equal(retLedgerUUID, ledgerUUID) // Returned ledger UUID should match input
			is.Equal(retUserData, testUserID)  // Returned user_data should match simulated user
			is.True(!retDescription.Valid)     // Description should be null initially
			is.Equal(retMetadata.Status, pgtype.Null) // Metadata should be null initially (check Status)

			categoryUUID = retUUID // Store for later verification and tests
		})

		// 2. Verify Database State
		t.Run("VerifyDatabase", func(t *testing.T) {
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
				dbMetadata     pgtype.Map // Use pgtype.Map for jsonb
			)

			// Query the data.accounts table directly
			err := conn.QueryRow(ctx,
				`SELECT id, ledger_id, name, type, internal_type, user_data, description, metadata
                 FROM data.accounts WHERE uuid = $1`, categoryUUID).Scan(
				&dbID,
				&dbLedgerID,
				&dbName,
				&dbType,
				&dbInternalType,
				&dbUserData,
				&dbDescription,
				&dbMetadata,
			)
			is.NoErr(err) // Should find the account in the database

			// Assert Database Values
			is.Equal(dbLedgerID, ledgerID)         // Ledger ID should match the one created earlier
			is.Equal(dbName, categoryName)         // Name should match
			is.Equal(dbType, "equity")             // Type should be 'equity'
			is.Equal(dbInternalType, "liability_like") // Internal type should be 'liability_like'
			is.Equal(dbUserData, testUserID)       // User data should match
			is.True(!dbDescription.Valid)          // Description should be null
			is.Equal(dbMetadata.Status, pgtype.Null) // Metadata should be null (check Status)
		})

		// 3. Test Error Case: Duplicate Name
		t.Run("DuplicateNameError", func(t *testing.T) {
			is := is_.New(t) // is instance for this subtest
			// Skip if the category wasn't created successfully
			if categoryUUID == "" {
				t.Skip("Skipping DuplicateNameError because category UUID was not captured")
			}

			// Call add_category again with the same name
			_, err := conn.Exec(ctx, "SELECT api.add_category($1, $2)", ledgerUUID, categoryName)
			is.True(err != nil) // Should return an error

			// Check for PostgreSQL unique violation error (code 23505)
			var pgErr *pgconn.PgError
			is.True(errors.As(err, &pgErr)) // Error should be a PgError
			is.Equal(pgErr.Code, "23505")   // Error code should be unique_violation
		})

		// 4. Test Error Case: Invalid Ledger
		t.Run("InvalidLedgerError", func(t *testing.T) {
			is := is_.New(t) // is instance for this subtest
			invalidLedgerUUID := "00000000-0000-0000-0000-000000000000" // Or any non-existent UUID

			_, err := conn.Exec(ctx, "SELECT api.add_category($1, $2)", invalidLedgerUUID, "Another Category")
			is.True(err != nil) // Should return an error

			// Check for the specific error message from utils.add_category
			var pgErr *pgconn.PgError
			is.True(errors.As(err, &pgErr)) // Error should be a PgError
			// Check the Detail or Message field for the specific exception text
			// Note: The exact field (Message vs Detail) might depend on PostgreSQL version and error context
			is.True(strings.Contains(pgErr.Message, "Ledger not found") || strings.Contains(pgErr.Detail, "Ledger not found"))
		})

		// 5. Test Error Case: Empty Name
		t.Run("EmptyNameError", func(t *testing.T) {
			is := is_.New(t) // is instance for this subtest

			_, err := conn.Exec(ctx, "SELECT api.add_category($1, $2)", ledgerUUID, "")
			is.True(err != nil) // Should return an error

			// Check for the specific error message from utils.add_category
			var pgErr *pgconn.PgError
			is.True(errors.As(err, &pgErr)) // Error should be a PgError
			// Check the Detail or Message field for the specific exception text
			is.True(strings.Contains(pgErr.Message, "Category name cannot be empty") || strings.Contains(pgErr.Detail, "Category name cannot be empty"))
		})
	})


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

