package main

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/matryer/is"
	"github.com/rs/zerolog"

	"github.com/j0lvera/pgbudget/testutils"
)

var (
	testDSN string
)

func TestMain(m *testing.M) {
	// Setup logging
	log := zerolog.New(os.Stdout).With().Timestamp().Logger()

	// Create a context with timeout for setup
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Configure and start the PostgreSQL container
	cfg := testutils.NewConfig()
	cfg.WithLogger(&log).WithMigrationsPath("migrations")

	pgContainer := testutils.NewPgContainer(cfg)
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

// TestDatabaseConnection verifies we can connect to the test database
func TestDatabaseConnection(t *testing.T) {
	is := is.New(t)
	ctx := context.Background()

	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err) // Should connect to database without error
	defer conn.Close(ctx)

	// Verify connection works with a simple query
	var result int
	err = conn.QueryRow(ctx, "SELECT 1").Scan(&result)
	is.NoErr(err)       // Should execute query without error
	is.Equal(1, result) // Should return expected result
}

// TestCreateLedger tests the creation of a new ledger
func TestCreateLedger(t *testing.T) {
	is := is.New(t)
	ctx := context.Background()

	ledgerName := "Test Budget"

	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err) // Should connect to database without error
	defer conn.Close(ctx)

	// Create a new ledger
	var ledgerID int
	err = conn.QueryRow(
		ctx,
		"INSERT INTO data.ledgers (name) VALUES ($1) RETURNING id",
		ledgerName,
	).Scan(&ledgerID)
	is.NoErr(err)         // Should create ledger without error
	is.True(ledgerID > 0) // Should return a valid ledger ID

	// Verify the ledger was created correctly
	var name string
	err = conn.QueryRow(
		ctx,
		"SELECT name FROM data.ledgers WHERE id = $1",
		ledgerID,
	).Scan(&name)
	is.NoErr(err)              // Should find the created ledger
	is.Equal(ledgerName, name) // Ledger should have the correct name
}

// TestCreateAccount tests the creation of accounts in a ledger
//func TestCreateAccount(t *testing.T) {
//	is := is.New(t)
//	ctx := context.Background()
//
//	// Connect to the database
//	conn, err := pgx.Connect(ctx, testDSN)
//	is.NoErr(err) // Should connect to database without error
//	defer conn.Close(ctx)
//
//	// Create a test ledger
//	var ledgerID int
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.create_ledger($1)",
//		"Account Test Ledger",
//	).Scan(&ledgerID)
//	is.NoErr(err) // Should create ledger without error
//
//	// Test cases for different account types
//	testCases := []struct {
//		name              string
//		accountType       string
//		shouldBeAssetLike bool
//	}{
//		{"Checking", "asset", true},
//		{"Credit Card", "liability", false},
//		{"Groceries", "equity", false},
//		{"Salary", "equity", false},
//	}
//
//	for _, tc := range testCases {
//		t.Run(
//			fmt.Sprintf("Account type: %s", tc.accountType),
//			func(t *testing.T) {
//				is := is.New(t) // Create a new instance for each subtest
//				var accountID int
//				err = conn.QueryRow(
//					ctx,
//					"SELECT api.create_account($1, $2, $3)",
//					ledgerID, tc.name, tc.accountType,
//				).Scan(&accountID)
//				is.NoErr(err) // Should create account without error
//				is.True(accountID > 0) // Should return a valid account ID
//
//				// Verify the account was created correctly
//				var name string
//				var accountType string
//				var isAssetLike bool
//				err = conn.QueryRow(
//					ctx,
//					"SELECT name, type, is_asset_like FROM data.accounts WHERE id = $1",
//					accountID,
//				).Scan(&name, &accountType, &isAssetLike)
//				is.NoErr(err) // Should find the created account
//				is.Equal(tc.name, name) // Account should have the correct name
//				is.Equal(tc.accountType, accountType) // Account should have the correct type
//				is.Equal(tc.shouldBeAssetLike, isAssetLike) // Account should have correct is_asset_like value
//			},
//		)
//	}
//}

// TestTransaction tests creating and retrieving transactions
//func TestTransaction(t *testing.T) {
//	is := is.New(t)
//	ctx := context.Background()
//
//	// Connect to the database
//	conn, err := pgx.Connect(ctx, testDSN)
//	is.NoErr(err) // Should connect to database without error
//	defer conn.Close(ctx)
//
//	// Create a test ledger
//	var ledgerID int
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.create_ledger($1)",
//		"Transaction Test Ledger",
//	).Scan(&ledgerID)
//	is.NoErr(err) // Should create ledger without error
//
//	// Create test accounts
//	var checkingID, groceriesID int
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.create_account($1, $2, $3)",
//		ledgerID, "Checking", "asset",
//	).Scan(&checkingID)
//	is.NoErr(err) // Should create checking account without error
//
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.create_account($1, $2, $3)",
//		ledgerID, "Groceries", "equity",
//	).Scan(&groceriesID)
//	is.NoErr(err) // Should create groceries account without error
//
//	// Create a transaction
//	var txID int
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.create_transaction($1, $2, $3, $4, $5, $6)",
//		ledgerID,
//		"Grocery shopping",
//		"2023-01-01",
//		checkingID,
//		groceriesID,
//		50.00,
//	).Scan(&txID)
//	is.NoErr(err) // Should create transaction without error
//	is.True(txID > 0) // Should return a valid transaction ID
//
//	// Verify transaction entries were created correctly
//	var count int
//	err = conn.QueryRow(
//		ctx,
//		"SELECT COUNT(*) FROM data.entries WHERE transaction_id = $1",
//		txID,
//	).Scan(&count)
//	is.NoErr(err) // Should query entries without error
//	is.Equal(2, count) // Transaction should have exactly 2 entries
//
//	// Verify account balances
//	var checkingBalance, groceriesBalance float64
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.get_account_balance($1)",
//		checkingID,
//	).Scan(&checkingBalance)
//	is.NoErr(err) // Should get checking balance without error
//	is.Equal(-50.00, checkingBalance) // Checking account should be debited
//
//	err = conn.QueryRow(
//		ctx,
//		"SELECT api.get_account_balance($1)",
//		groceriesID,
//	).Scan(&groceriesBalance)
//	is.NoErr(err) // Should get groceries balance without error
//	is.Equal(-50.00, groceriesBalance) // Groceries account should be debited
//}
