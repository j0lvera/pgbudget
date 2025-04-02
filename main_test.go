package main

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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
	ctx := context.Background()
	
	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	require.NoError(t, err, "Should connect to database without error")
	defer conn.Close(ctx)
	
	// Verify connection works with a simple query
	var result int
	err = conn.QueryRow(ctx, "SELECT 1").Scan(&result)
	require.NoError(t, err, "Should execute query without error")
	assert.Equal(t, 1, result, "Should return expected result")
}

// TestCreateLedger tests the creation of a new ledger
func TestCreateLedger(t *testing.T) {
	ctx := context.Background()
	
	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	require.NoError(t, err, "Should connect to database without error")
	defer conn.Close(ctx)
	
	// Create a new ledger
	var ledgerID int
	err = conn.QueryRow(ctx, 
		"SELECT api.create_ledger($1)", 
		"Test Ledger",
	).Scan(&ledgerID)
	require.NoError(t, err, "Should create ledger without error")
	assert.Greater(t, ledgerID, 0, "Should return a valid ledger ID")
	
	// Verify the ledger was created correctly
	var name string
	err = conn.QueryRow(ctx, 
		"SELECT name FROM data.ledgers WHERE id = $1", 
		ledgerID,
	).Scan(&name)
	require.NoError(t, err, "Should find the created ledger")
	assert.Equal(t, "Test Ledger", name, "Ledger should have the correct name")
}

// TestCreateAccount tests the creation of accounts in a ledger
func TestCreateAccount(t *testing.T) {
	ctx := context.Background()
	
	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	require.NoError(t, err, "Should connect to database without error")
	defer conn.Close(ctx)
	
	// Create a test ledger
	var ledgerID int
	err = conn.QueryRow(ctx, 
		"SELECT api.create_ledger($1)", 
		"Account Test Ledger",
	).Scan(&ledgerID)
	require.NoError(t, err, "Should create ledger without error")
	
	// Test cases for different account types
	testCases := []struct {
		name        string
		accountType string
		shouldBeAssetLike bool
	}{
		{"Checking", "asset", true},
		{"Credit Card", "liability", false},
		{"Groceries", "equity", false},
		{"Salary", "equity", false},
	}
	
	for _, tc := range testCases {
		t.Run(fmt.Sprintf("Account type: %s", tc.accountType), func(t *testing.T) {
			var accountID int
			err = conn.QueryRow(ctx, 
				"SELECT api.create_account($1, $2, $3)", 
				ledgerID, tc.name, tc.accountType,
			).Scan(&accountID)
			require.NoError(t, err, "Should create account without error")
			assert.Greater(t, accountID, 0, "Should return a valid account ID")
			
			// Verify the account was created correctly
			var name string
			var accountType string
			var isAssetLike bool
			err = conn.QueryRow(ctx, 
				"SELECT name, type, is_asset_like FROM data.accounts WHERE id = $1", 
				accountID,
			).Scan(&name, &accountType, &isAssetLike)
			require.NoError(t, err, "Should find the created account")
			assert.Equal(t, tc.name, name, "Account should have the correct name")
			assert.Equal(t, tc.accountType, accountType, "Account should have the correct type")
			assert.Equal(t, tc.shouldBeAssetLike, isAssetLike, "Account should have correct is_asset_like value")
		})
	}
}

// TestTransaction tests creating and retrieving transactions
func TestTransaction(t *testing.T) {
	ctx := context.Background()
	
	// Connect to the database
	conn, err := pgx.Connect(ctx, testDSN)
	require.NoError(t, err, "Should connect to database without error")
	defer conn.Close(ctx)
	
	// Create a test ledger
	var ledgerID int
	err = conn.QueryRow(ctx, 
		"SELECT api.create_ledger($1)", 
		"Transaction Test Ledger",
	).Scan(&ledgerID)
	require.NoError(t, err, "Should create ledger without error")
	
	// Create test accounts
	var checkingID, groceriesID int
	err = conn.QueryRow(ctx, 
		"SELECT api.create_account($1, $2, $3)", 
		ledgerID, "Checking", "asset",
	).Scan(&checkingID)
	require.NoError(t, err, "Should create checking account without error")
	
	err = conn.QueryRow(ctx, 
		"SELECT api.create_account($1, $2, $3)", 
		ledgerID, "Groceries", "equity",
	).Scan(&groceriesID)
	require.NoError(t, err, "Should create groceries account without error")
	
	// Create a transaction
	var txID int
	err = conn.QueryRow(ctx, 
		"SELECT api.create_transaction($1, $2, $3, $4, $5, $6)", 
		ledgerID, 
		"Grocery shopping",
		"2023-01-01",
		checkingID, 
		groceriesID, 
		50.00,
	).Scan(&txID)
	require.NoError(t, err, "Should create transaction without error")
	assert.Greater(t, txID, 0, "Should return a valid transaction ID")
	
	// Verify transaction entries were created correctly
	var count int
	err = conn.QueryRow(ctx, 
		"SELECT COUNT(*) FROM data.entries WHERE transaction_id = $1", 
		txID,
	).Scan(&count)
	require.NoError(t, err, "Should query entries without error")
	assert.Equal(t, 2, count, "Transaction should have exactly 2 entries")
	
	// Verify account balances
	var checkingBalance, groceriesBalance float64
	err = conn.QueryRow(ctx, 
		"SELECT api.get_account_balance($1)", 
		checkingID,
	).Scan(&checkingBalance)
	require.NoError(t, err, "Should get checking balance without error")
	assert.Equal(t, -50.00, checkingBalance, "Checking account should be debited")
	
	err = conn.QueryRow(ctx, 
		"SELECT api.get_account_balance($1)", 
		groceriesID,
	).Scan(&groceriesBalance)
	require.NoError(t, err, "Should get groceries balance without error")
	assert.Equal(t, -50.00, groceriesBalance, "Groceries account should be debited")
}
