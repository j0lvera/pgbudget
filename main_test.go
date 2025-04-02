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

// TestDatabase uses nested subtests to share context between tests
func TestDatabase(t *testing.T) {
	// Setup logging
	log := zerolog.New(os.Stdout).With().Timestamp().Logger()

	is := is.New(t)
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

	// Basic connection test
	t.Run(
		"Connection", func(t *testing.T) {
			is := is.New(t)

			// Verify connection works with a simple query
			var result int
			err = conn.QueryRow(ctx, "SELECT 1").Scan(&result)
			is.NoErr(err)       // Should execute query without error
			is.Equal(1, result) // Should return expected result
		},
	)

	// Create a ledger and store its ID for subsequent tests
	var ledgerID int
	t.Run(
		"CreateLedger", func(t *testing.T) {
			is := is.New(t)

			ledgerName := "Test Budget"

			// Create a new ledger
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

			// Verify that the internal accounts were created
			var accountNames []string
			err = conn.QueryRow(
				ctx,
				"SELECT name FROM data.accounts WHERE ledger_id = $1",
				ledgerID,
			).Scan(&accountNames)
			log.Info().Interface("accounts", accountNames).Msg("Accounts")
			is.NoErr(err) // Should query accounts without error
			is.Equal(
				accountNames[0], "Income",
			)
		},
	)

	// Test account creation using the ledger created above
	t.Run(
		"CreateAccounts", func(t *testing.T) {
			// Skip if ledger creation failed
			if ledgerID <= 0 {
				t.Skip("Skipping because ledger creation failed")
			}

			// Test cases for different account types
			testCases := []struct {
				name              string
				accountType       string
				shouldBeAssetLike bool
			}{
				{"Checking", "asset", true},
				{"Credit Card", "liability", false},
				{"Groceries", "equity", false},
				{"Salary", "equity", false},
			}

			// Store account IDs for later tests
			accountIDs := make(map[string]int)

			for _, tc := range testCases {
				t.Run(
					"AccountType_"+tc.accountType,
					func(t *testing.T) {
						is := is.New(t) // Create a new instance for each subtest
						var accountID int
						err = conn.QueryRow(
							ctx,
							"INSERT INTO data.accounts (ledger_id, name, type, is_asset_like) VALUES ($1, $2, $3, $4) RETURNING id",
							ledgerID, tc.name, tc.accountType,
							tc.shouldBeAssetLike,
						).Scan(&accountID)
						is.NoErr(err)          // Should create account without error
						is.True(accountID > 0) // Should return a valid account ID

						// Store the account ID for later use
						accountIDs[tc.name] = accountID

						// Verify the account was created correctly
						var name string
						var accountType string
						var isAssetLike bool
						err = conn.QueryRow(
							ctx,
							"SELECT name, type, is_asset_like FROM data.accounts WHERE id = $1",
							accountID,
						).Scan(&name, &accountType, &isAssetLike)
						is.NoErr(err) // Should find the created account
						is.Equal(
							tc.name, name,
						) // Account should have the correct name
						is.Equal(
							tc.accountType, accountType,
						) // Account should have the correct type
						is.Equal(
							tc.shouldBeAssetLike, isAssetLike,
						) // Account should have correct is_asset_like value
					},
				)
			}

			// Test transactions using the accounts created above
			t.Run(
				"CreateTransaction", func(t *testing.T) {
					is := is.New(t)

					// Skip if we don't have the required accounts
					checkingID, hasChecking := accountIDs["Checking"]
					groceriesID, hasGroceries := accountIDs["Groceries"]
					if !hasChecking || !hasGroceries {
						t.Skip("Skipping because required accounts were not created")
					}

					// Create a transaction
					var txID int
					err = conn.QueryRow(
						ctx,
						`INSERT INTO data.transactions (ledger_id, description, date) 
				 VALUES ($1, $2, $3) RETURNING id`,
						ledgerID, "Grocery shopping", "2023-01-01",
					).Scan(&txID)
					is.NoErr(err)     // Should create transaction without error
					is.True(txID > 0) // Should return a valid transaction ID

					// Create entries for the transaction
					_, err = conn.Exec(
						ctx,
						`INSERT INTO data.entries (transaction_id, account_id, amount) 
				 VALUES ($1, $2, $3), ($1, $4, $5)`,
						txID, checkingID, -50.00, groceriesID, -50.00,
					)
					is.NoErr(err) // Should create entries without error

					// Verify transaction entries were created correctly
					var count int
					err = conn.QueryRow(
						ctx,
						"SELECT COUNT(*) FROM data.entries WHERE transaction_id = $1",
						txID,
					).Scan(&count)
					is.NoErr(err) // Should query entries without error
					is.Equal(
						2, count,
					) // Transaction should have exactly 2 entries

					// Verify account balances
					var checkingBalance float64
					err = conn.QueryRow(
						ctx,
						`SELECT COALESCE(SUM(amount), 0) 
				 FROM data.entries 
				 WHERE account_id = $1`,
						checkingID,
					).Scan(&checkingBalance)
					is.NoErr(err) // Should get checking balance without error
					is.Equal(
						-50.00, checkingBalance,
					) // Checking account should be debited

					var groceriesBalance float64
					err = conn.QueryRow(
						ctx,
						`SELECT COALESCE(SUM(amount), 0) 
				 FROM data.entries 
				 WHERE account_id = $1`,
						groceriesID,
					).Scan(&groceriesBalance)
					is.NoErr(err) // Should get groceries balance without error
					is.Equal(
						-50.00, groceriesBalance,
					) // Groceries account should be debited
				},
			)
		},
	)
}
