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

// Helper function to check if a slice contains a string
func contains(slice []string, str string) bool {
	for _, item := range slice {
		if item == str {
			return true
		}
	}
	return false
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
			rows, err := conn.Query(
				ctx,
				"SELECT name FROM data.accounts WHERE ledger_id = $1 ORDER BY name",
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

	// Test account creation using the ledger created above
	t.Run(
		"CreateAccounts", func(t *testing.T) {
			// Skip if ledger creation failed
			if ledgerID <= 0 {
				t.Skip("Skipping because ledger creation failed")
			}

			// Test cases for different account types
			testCases := []struct {
				name         string
				accountType  string
				internalType string
			}{
				{"Checking", "asset", "asset_like"},
				{"Credit Card", "liability", "liability_like"},
				{"Groceries", "equity", "liability_like"},
				{"Salary", "equity", "liability_like"},
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
							"INSERT INTO data.accounts (ledger_id, name, type, internal_type) VALUES ($1, $2, $3, $4) RETURNING id",
							ledgerID, tc.name, tc.accountType, tc.internalType,
						).Scan(&accountID)
						is.NoErr(err)          // Should create account without error
						is.True(accountID > 0) // Should return a valid account ID

						// Store the account ID for later use
						accountIDs[tc.name] = accountID

						// Verify the account was created correctly
						var name string
						var accountType string
						var internalType string
						err = conn.QueryRow(
							ctx,
							"SELECT name, type, internal_type FROM data.accounts WHERE id = $1",
							accountID,
						).Scan(&name, &accountType, &internalType)
						is.NoErr(err) // Should find the created account
						is.Equal(
							tc.name, name,
						) // Account should have the correct name
						is.Equal(
							tc.accountType, accountType,
						) // Account should have the correct type
						is.Equal(
							tc.internalType, internalType,
						) // Account should have correct internal type
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

					// Create a transaction with proper debit and credit accounts
					var txID int
					err = conn.QueryRow(
						ctx,
						`INSERT INTO data.transactions (ledger_id, description, date, debit_account_id, credit_account_id, amount) 
				 VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
						ledgerID, "Grocery shopping", "2023-01-01", groceriesID, checkingID, 50.00,
					).Scan(&txID)
					is.NoErr(err)     // Should create transaction without error
					is.True(txID > 0) // Should return a valid transaction ID

					// Verify the transaction was created correctly
					var description string
					var debitAccountID int
					var creditAccountID int
					var amount float64
					err = conn.QueryRow(
						ctx,
						"SELECT description, debit_account_id, credit_account_id, amount FROM data.transactions WHERE id = $1",
						txID,
					).Scan(&description, &debitAccountID, &creditAccountID, &amount)
					is.NoErr(err) // Should find the created transaction
					is.Equal("Grocery shopping", description) // Transaction should have the correct description
					is.Equal(groceriesID, debitAccountID)     // Transaction should debit the groceries account
					is.Equal(checkingID, creditAccountID)     // Transaction should credit the checking account
					is.Equal(50.00, amount)                   // Transaction should have the correct amount
				},
			)
		},
	)

	// Test the find_category function
	t.Run("FindCategory", func(t *testing.T) {
		is := is.New(t)
		
		// Skip if ledger creation failed
		if ledgerID <= 0 {
			t.Skip("Skipping because ledger creation failed")
		}
		
		// Test cases for different categories
		testCases := []struct {
			name           string
			expectedToFind bool
		}{
			{"Income", true},        // Should find the default Income category
			{"Unassigned", true},    // Should find the default Unassigned category
			{"Off-budget", true},    // Should find the default Off-budget category
			{"Groceries", true},     // Should find the Groceries category we created
			{"NonExistentCategory", false}, // Should not find a non-existent category
		}
		
		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				is := is.New(t) // Create a new instance for each subtest
				
				var categoryID int
				var found bool
				
				// Call the find_category function
				err := conn.QueryRow(
					ctx,
					"SELECT api.find_category($1, $2)",
					ledgerID, tc.name,
				).Scan(&categoryID)
				
				// Check if category was found
				if err != nil {
					if tc.expectedToFind {
						is.NoErr(err) // Should not have errors for categories we expect to find
					} else {
						// We expect an error for non-existent categories
						found = false
					}
				} else {
					found = categoryID > 0
				}
				
				if tc.expectedToFind {
					is.True(found) // Category should be found
					is.True(categoryID > 0) // Should return a valid category ID
					
					var name string
					err = conn.QueryRow(
						ctx,
						"SELECT name FROM data.accounts WHERE id = $1 AND ledger_id = $2",
						categoryID, ledgerID,
					).Scan(&name)
					is.NoErr(err) // Should find the category
					is.Equal(tc.name, name) // Category should have the correct name
				}
			})
		}
	})

	// Test the get_budget_status function
	t.Run("GetBudgetStatus", func(t *testing.T) {
		is := is.New(t)
		
		// Skip if ledger creation failed
		if ledgerID <= 0 {
			t.Skip("Skipping because ledger creation failed")
		}
		
		// First, create a transaction to budget money from Income to Groceries
		// Find the Income account ID
		var incomeID int
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE ledger_id = $1 AND name = 'Income'",
			ledgerID,
		).Scan(&incomeID)
		is.NoErr(err) // Should find the Income account
		
		// Find the Groceries account ID
		var groceriesID int
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE ledger_id = $1 AND name = 'Groceries'",
			ledgerID,
		).Scan(&groceriesID)
		is.NoErr(err) // Should find the Groceries account
		
		// Find the Checking account ID
		var checkingID int
		err = conn.QueryRow(
			ctx,
			"SELECT id FROM data.accounts WHERE ledger_id = $1 AND name = 'Checking'",
			ledgerID,
		).Scan(&checkingID)
		is.NoErr(err) // Should find the Checking account
		
		// 1. Create a transaction to simulate receiving income
		var incomeTxID int
		err = conn.QueryRow(
			ctx,
			`INSERT INTO data.transactions (ledger_id, description, date, debit_account_id, credit_account_id, amount) 
			VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
			ledgerID, "Salary deposit", "2023-01-01", checkingID, incomeID, 1000.00,
		).Scan(&incomeTxID)
		is.NoErr(err) // Should create income transaction without error
		
		// 2. Create a transaction to budget money from Income to Groceries
		var budgetTxID int
		err = conn.QueryRow(
			ctx,
			`INSERT INTO data.transactions (ledger_id, description, date, debit_account_id, credit_account_id, amount) 
			VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
			ledgerID, "Budget for groceries", "2023-01-01", incomeID, groceriesID, 200.00,
		).Scan(&budgetTxID)
		is.NoErr(err) // Should create budgeting transaction without error
		
		// 3. Create a transaction to spend from Groceries
		var spendTxID int
		err = conn.QueryRow(
			ctx,
			`INSERT INTO data.transactions (ledger_id, description, date, debit_account_id, credit_account_id, amount) 
			VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
			ledgerID, "Grocery shopping", "2023-01-02", groceriesID, checkingID, 75.00,
		).Scan(&spendTxID)
		is.NoErr(err) // Should create spending transaction without error
		
		// Now call the get_budget_status function and verify the results
		rows, err := conn.Query(
			ctx,
			"SELECT * FROM api.get_budget_status($1) WHERE account_name = 'Groceries'",
			ledgerID,
		)
		is.NoErr(err) // Should query budget status without error
		defer rows.Close()
		
		// We should have one row for Groceries
		is.True(rows.Next()) // Should have at least one row
		
		var id int
		var accountName string
		var budgeted float64
		var activity float64
		var balance float64
		
		err = rows.Scan(&id, &accountName, &budgeted, &activity, &balance)
		is.NoErr(err) // Should scan row without error
		
		// Verify the budget status values
		is.Equal("Groceries", accountName) // Should be the Groceries account
		is.Equal(200.00, budgeted)         // Should show $200 budgeted
		is.Equal(-75.00, activity)         // Should show -$75 activity (money spent)
		is.Equal(125.00, balance)          // Should show $125 balance ($200 - $75)
		
		// Make sure there are no more rows for Groceries
		is.False(rows.Next()) // Should have exactly one row for Groceries
		
		// Check for any errors from iterating over rows
		is.NoErr(rows.Err())
	})
}
