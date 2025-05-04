package main

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/j0lvera/pgbudget/testutils/pgcontainer"
	"github.com/jackc/pgx/v5"
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
	cfg.WithLogger(&log).WithMigrationsPath("../migrations")

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
	var checkingID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.add_account($1, $2, $3)",
		ledgerID, "Checking", "asset",
	).Scan(&checkingID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create checking account: %w", err,
		)
	}
	accounts["Checking"] = checkingID

	// Create groceries category using api.add_category
	var groceriesID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.add_category($1, $2)",
		ledgerID, "Groceries",
	).Scan(&groceriesID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create groceries category: %w", err,
		)
	}
	accounts["Groceries"] = groceriesID

	// Find the Income account (should be created automatically with the ledger)
	var incomeID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.find_category($1, $2)",
		ledgerID, "Income",
	).Scan(&incomeID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to find income category: %w", err,
		)
	}
	accounts["Income"] = incomeID

	// 1. Create a transaction to simulate receiving income
	var incomeTxID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.add_transaction($1, $2, $3, $4, $5, $6, $7)",
		ledgerID, "2023-01-01", "Salary deposit", "inflow",
		100000, // $1000.00
		checkingID, incomeID,
	).Scan(&incomeTxID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create income transaction: %w", err,
		)
	}
	transactions["Income"] = incomeTxID

	// 2. Create a transaction to budget money from Income to Groceries
	var budgetTxID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.assign_to_category($1, $2, $3, $4, $5)",
		ledgerID, "2023-01-01", "Budget allocation to Groceries",
		30000, // $300.00
		groceriesID,
	).Scan(&budgetTxID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create budget transaction: %w", err,
		)
	}
	transactions["Budget"] = budgetTxID

	// 3. Create a transaction to spend from Groceries
	var spendTxID int
	err = conn.QueryRow(
		ctx,
		"SELECT api.add_transaction($1, $2, $3, $4, $5, $6, $7)",
		ledgerID, "2023-01-02", "Grocery shopping", "outflow",
		7500, // $75.00
		checkingID, groceriesID,
	).Scan(&spendTxID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf(
			"failed to create spending transaction: %w", err,
		)
	}
	transactions["Spend"] = spendTxID

	return ledgerID, accounts, transactions, nil
}

// TestDatabase uses nested subtests to share context between tests
func TestDatabase(t *testing.T) {
	is := is_.New(t)
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

	// Set a dummy JWT claim for the test session to simulate PostgREST authentication
	// This is necessary because some functions/triggers might rely on request.jwt.claims
	_, err = conn.Exec(ctx, `SELECT set_config('request.jwt.claims', '{"role": "test_user", "email": "test@example.com"}', true)`)
	is.NoErr(err) // Should set config without error

	// Basic connection test
	t.Run(
		"Connection", func(t *testing.T) {
			is := is_.New(t)

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
			is := is_.New(t)

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
