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
	err := conn.QueryRow(
		ctx,
		"INSERT INTO data.ledgers (name) VALUES ($1) RETURNING id",
		ledgerName,
	).Scan(&ledgerID)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("failed to create ledger: %w", err)
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

	// Create a ledger and store its ID for subsequent tests
	var ledgerID int
	t.Run(
		"CreateLedger", func(t *testing.T) {
			is := is_.New(t)

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
						is := is_.New(t) // Create a new instance for each subtest
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
					is := is_.New(t)

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
						ledgerID, "Grocery shopping", "2023-01-01", groceriesID,
						checkingID, 50.00,
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
					).Scan(
						&description, &debitAccountID, &creditAccountID,
						&amount,
					)
					is.NoErr(err) // Should find the created transaction
					is.Equal(
						"Grocery shopping", description,
					) // Transaction should have the correct description
					is.Equal(
						groceriesID, debitAccountID,
					) // Transaction should debit the groceries account
					is.Equal(
						checkingID, creditAccountID,
					) // Transaction should credit the checking account
					is.Equal(
						50.00, amount,
					) // Transaction should have the correct amount
				},
			)
		},
	)

	// Test the find_category function
	t.Run(
		"FindCategory", func(t *testing.T) {
			// Skip if ledger creation failed
			if ledgerID <= 0 {
				t.Skip("Skipping because ledger creation failed")
			}

			// Test cases for different categories
			testCases := []struct {
				name           string
				expectedToFind bool
			}{
				{"Income", true}, // Should find the default Income category
				{
					"Unassigned", true,
				}, // Should find the default Unassigned category
				{
					"Off-budget", true,
				}, // Should find the default Off-budget category
				{
					"Groceries", true,
				}, // Should find the Groceries category we created
				{
					"NonExistentCategory", false,
				}, // Should not find a non-existent category
			}

			for _, tc := range testCases {
				t.Run(
					tc.name, func(t *testing.T) {
						is := is_.New(t) // Create a new instance for each subtest

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
							is.True(found)          // Category should be found
							is.True(categoryID > 0) // Should return a valid category ID

							var name string
							err = conn.QueryRow(
								ctx,
								"SELECT name FROM data.accounts WHERE id = $1 AND ledger_id = $2",
								categoryID, ledgerID,
							).Scan(&name)
							is.NoErr(err) // Should find the category
							is.Equal(
								tc.name, name,
							) // Category should have the correct name
						}
					},
				)
			}
		},
	)

	// Test the get_budget_status function with a fresh ledger
	t.Run(
		"GetBudgetStatus", func(t *testing.T) {
			is := is_.New(t)

			// Use the helper function to set up a test ledger
			ledgerID, _, _, err := setupTestLedger(
				ctx, conn, "Budget Status Test Ledger",
			)
			is.NoErr(err) // Should set up test ledger without error

			// First, get all budget status rows to debug what's available
			rows, err := conn.Query(
				ctx,
				"SELECT * FROM api.get_budget_status($1)",
				ledgerID,
			)
			is.NoErr(err) // Should query budget status without error
			defer rows.Close()

			// Collect all account names for debugging
			var accountNamesList []string
			for rows.Next() {
				var accountID int
				var accountName string
				var budgeted float64
				var activity float64
				var available float64

				err = rows.Scan(
					&accountID, &accountName, &budgeted, &activity, &available,
				)
				is.NoErr(err) // Should scan row without error
				accountNamesList = append(accountNamesList, accountName)
			}
			is.NoErr(rows.Err())

			// Now query specifically for Groceries
			rows, err = conn.Query(
				ctx,
				"SELECT * FROM api.get_budget_status($1) t WHERE t.account_name = 'Groceries'",
				ledgerID,
			)
			is.NoErr(err) // Should query budget status without error
			defer rows.Close()

			// We should have one row for Groceries
			is.True(rows.Next()) // Should have at least one row

			var accountID int
			var accountName string
			var budgeted int
			var activity int
			var available int

			err = rows.Scan(
				&accountID, &accountName, &budgeted, &activity, &available,
			)
			is.NoErr(err) // Should scan row without error

			// Verify the budget status values
			is.Equal(
				"Groceries", accountName,
			)                         // Should be the Groceries account
			is.Equal(30000, budgeted) // Should show $300 budgeted
			is.Equal(
				-7500, activity,
			) // Should show -$75 activity (money spent)
			is.Equal(
				22500, available,
			) // Should show $225 available ($300 - $75)

			// Make sure there are no more rows for Groceries
			is.True(!rows.Next()) // Should have exactly one row for Groceries

			// Check for any errors from iterating over rows
			is.NoErr(rows.Err())
		},
	)

	// Test the get_account_balance function
	t.Run(
		"GetAccountBalance", func(t *testing.T) {
			is := is_.New(t)

			// Use the helper function to set up a test ledger
			ledgerID, accounts, _, err := setupTestLedger(
				ctx, conn, "Balance Test Ledger",
			)
			is.NoErr(err) // Should set up test ledger without error

			// Create credit card account - this is not created by setupTestLedger
			var creditCardID int
			err = conn.QueryRow(
				ctx,
				"SELECT api.add_account($1, $2, $3)",
				ledgerID, "Credit Card", "liability",
			).Scan(&creditCardID)
			is.NoErr(err) // Should create credit card account without error

			// 4. Create a transaction to spend from Groceries using credit card
			var creditSpendTxID int
			err = conn.QueryRow(
				ctx,
				"select api.add_transaction($1, $2, $3, $4, $5, $6, $7)",
				ledgerID, "2023-01-03", "Grocery shopping with credit",
				"outflow",
				5000, // $50.00
				creditCardID, accounts["Groceries"],
			).Scan(&creditSpendTxID)
			is.NoErr(err) // Should create spending transaction without error

			// 5. Create a transaction to pay credit card from checking
			var paymentTxID int
			err = conn.QueryRow(
				ctx,
				"SELECT api.add_transaction($1, $2, $3, $4, $5, $6, $7)",
				ledgerID, "2023-01-04", "Credit card payment", "outflow",
				5000, // $50.00
				accounts["Checking"], creditCardID,
			).Scan(&paymentTxID)
			is.NoErr(err) // Should create payment transaction without error

			// Test cases for different account balances
			testCases := []struct {
				name          string
				accountID     int
				expectedValue int
			}{
				{
					"Checking", accounts["Checking"], 87500,
				}, // $1000 - $75 - $50 = $875.00
				{
					"Credit Card", creditCardID, -10000,
				}, // Credit card balance after transactions
				{
					"Groceries", accounts["Groceries"], 27500,
				}, // $300 - $75 + credit card adjustment = $275.00
				{
					"Income", accounts["Income"], 70000,
				}, // $1000 - $300 = $700.00
			}

			for _, tc := range testCases {
				t.Run(
					tc.name, func(t *testing.T) {
						is := is_.New(t) // Create a new instance for each subtest

						var balance int
						err = conn.QueryRow(
							ctx,
							"select api.get_account_balance($1, $2)",
							ledgerID, tc.accountID,
						).Scan(&balance)
						is.NoErr(err) // Should get balance without error

						// Verify the balance
						is.Equal(
							tc.expectedValue, balance,
						) // Balance should match expected value
					},
				)
			}
		},
	)

	// Test the balances table and trigger functionality
	t.Run(
		"BalancesTracking", func(t *testing.T) {
			is := is_.New(t)

			// Use the helper function to set up a test ledger
			_, accounts, transactions, err := setupTestLedger(
				ctx, conn, "Balances Tracking Test Ledger",
			)
			is.NoErr(err) // Should set up test ledger without error

			// Get the account IDs and transaction IDs
			checkingID := accounts["Checking"]
			groceriesID := accounts["Groceries"]
			incomeID := accounts["Income"]

			incomeTxID := transactions["Income"]
			budgetTxID := transactions["Budget"]
			spendTxID := transactions["Spend"]

			// Verify balances table entries for checking account
			t.Run(
				"CheckingBalances", func(t *testing.T) {
					is := is_.New(t)

					// Query all balance entries for checking account
					rows, err := conn.Query(
						ctx,
						`select transaction_id, previous_balance, delta, balance, operation_type 
				 from data.balances 
				 where account_id = $1 
				 order by created_at`,
						checkingID,
					)
					is.NoErr(err) // Should query balances without error
					defer rows.Close()

					// We should have at least two entries for checking
					// First entry: income transaction (debit/increase)
					is.True(rows.Next()) // Should have first row

					var txID int
					var prevBalance, delta, balance int
					var opType string

					err = rows.Scan(
						&txID, &prevBalance, &delta, &balance, &opType,
					)
					is.NoErr(err) // Should scan row without error

					is.Equal(
						incomeTxID, txID,
					)                         // Should be the income transaction
					is.Equal(0, prevBalance)  // First transaction starts at 0
					is.Equal(100000, delta)   // +$1000.00 delta
					is.Equal(100000, balance) // New balance should be $1000.00
					is.Equal(
						"debit", opType,
					) // Should be a debit operation (asset increase)

					// Second entry: spending transaction (credit/decrease)
					is.True(rows.Next()) // Should have second row

					err = rows.Scan(
						&txID, &prevBalance, &delta, &balance, &opType,
					)
					is.NoErr(err) // Should scan row without error

					is.Equal(
						spendTxID, txID,
					) // Should be the spending transaction
					is.Equal(
						100000, prevBalance,
					)                      // Previous balance should be $1000.00
					is.Equal(-7500, delta) // -$75.00 delta
					is.Equal(
						92500, balance,
					) // New balance should be $925.00
					is.Equal(
						"credit", opType,
					) // Should be a credit operation (asset decrease)
				},
			)

			// Verify balances table entries for a budget category
			t.Run(
				"CategoryBalances", func(t *testing.T) {
					is := is_.New(t)

					// Query all balance entries for the category account
					rows, err := conn.Query(
						ctx,
						`select transaction_id, previous_balance, delta, balance, operation_type 
				 from data.balances 
				 where account_id = $1 
				 order by created_at`,
						groceriesID,
					)
					is.NoErr(err) // Should query balances without error
					defer rows.Close()

					// We should have at least two entries for the category
					// First entry: budget allocation (credit/increase for liability-like)
					is.True(rows.Next()) // Should have first row

					var txID int
					var prevBalance, delta, balance int
					var opType string

					err = rows.Scan(
						&txID, &prevBalance, &delta, &balance, &opType,
					)
					is.NoErr(err) // Should scan row without error

					is.Equal(
						budgetTxID, txID,
					)                        // Should be the budget transaction
					is.Equal(0, prevBalance) // First transaction starts at 0
					is.Equal(
						-30000, delta,
					)                        // -$300.00 delta (negative for credit)
					is.Equal(30000, balance) // New balance should be $300.00
					is.Equal(
						"credit", opType,
					) // Should be a credit operation (liability increase)

					// Second entry: spending transaction (debit/decrease for liability-like)
					is.True(rows.Next()) // Should have second row

					err = rows.Scan(
						&txID, &prevBalance, &delta, &balance, &opType,
					)
					is.NoErr(err) // Should scan row without error

					is.Equal(
						spendTxID, txID,
					) // Should be the spending transaction
					is.Equal(
						30000, prevBalance,
					) // Previous balance should be $300.00
					is.Equal(
						7500, delta,
					) // +$75.00 delta (positive for debit)
					is.Equal(
						22500, balance,
					) // New balance should be $225.00
					is.Equal(
						"debit", opType,
					) // Should be a debit operation (liability decrease)
				},
			)

			// Verify the latest balance for each account matches what we expect
			t.Run(
				"LatestBalances", func(t *testing.T) {
					// Test cases for different account latest balances
					testCases := []struct {
						name          string
						accountID     int
						expectedValue int
					}{
						{
							"Checking", checkingID, 92500,
						}, // $1000 - $75 = $925.00
						{
							"Groceries", groceriesID, 22500,
						}, // $300 - $75 = $225.00
						{
							"Income", incomeID, 70000,
						}, // $1000 - $300 = $700.00
					}

					for _, tc := range testCases {
						t.Run(
							tc.name, func(t *testing.T) {
								is := is_.New(t) // Create a new instance for each subtest

								var balance int
								err := conn.QueryRow(
									ctx,
									`select balance from data.balances 
						 where account_id = $1 
						 order by created_at desc limit 1`,
									tc.accountID,
								).Scan(&balance)
								is.NoErr(err) // Should get balance without error

								// Verify the balance
								is.Equal(
									tc.expectedValue, balance,
								) // Balance should match expected value
							},
						)
					}
				},
			)
		},
	)

	// Test the get_account_transactions function with the new balance column
	t.Run("GetAccountTransactions", func(t *testing.T) {
		is := is_.New(t)

		// Use the helper function to set up a test ledger
		_, accounts, _, err := setupTestLedger(ctx, conn, "Account Transactions Test Ledger")
		is.NoErr(err) // Should set up test ledger without error

		// Get the checking account ID
		checkingID := accounts["Checking"]

		// Query transactions for the checking account
		rows, err := conn.Query(
			ctx,
			"SELECT date, category, description, type, amount, balance FROM api.get_account_transactions($1)",
			checkingID,
		)
		is.NoErr(err) // Should query account transactions without error
		defer rows.Close()

		// We should have at least two transactions for checking
		// Collect all transactions to verify them
		type transaction struct {
			date        time.Time
			category    string
			description string
			txType      string
			amount      int
			balance     int
		}

		var transactions_list []transaction
		for rows.Next() {
			var tx transaction
			var txDate time.Time
			err = rows.Scan(&txDate, &tx.category, &tx.description, &tx.txType, &tx.amount, &tx.balance)
			is.NoErr(err) // Should scan row without error
			tx.date = txDate
			transactions_list = append(transactions_list, tx)
		}
		is.NoErr(rows.Err()) // Should not have errors iterating rows

		// We should have at least 2 transactions (income and spending)
		is.True(len(transactions_list) >= 2) // Should have at least 2 transactions

		// Verify the transactions are in the correct order (newest first)
		if len(transactions_list) >= 2 {
			is.True(transactions_list[0].date.After(transactions_list[1].date) || 
					transactions_list[0].date.Equal(transactions_list[1].date)) // First transaction should be newer or same date
		}

		// Find and verify the income transaction
		var foundIncome bool
		for _, tx := range transactions_list {
			if tx.description == "Salary deposit" && tx.txType == "inflow" {
				foundIncome = true
				is.Equal("Income", tx.category) // Should be categorized as Income
				is.Equal(100000, tx.amount)     // Should be $1000.00
				is.Equal(100000, tx.balance)    // Balance should be $1000.00 after this transaction
			}
		}
		is.True(foundIncome) // Should find the income transaction

		// Find and verify the spending transaction
		var foundSpending bool
		for _, tx := range transactions_list {
			if tx.description == "Grocery shopping" && tx.txType == "outflow" {
				foundSpending = true
				is.Equal("Groceries", tx.category) // Should be categorized as Groceries
				is.Equal(-7500, tx.amount)         // Should be -$75.00
				is.Equal(92500, tx.balance)        // Balance should be $925.00 after this transaction
			}
		}
		is.True(foundSpending) // Should find the spending transaction

		// Verify the account_transactions view works too
		var viewCount int
		err = conn.QueryRow(
			ctx,
			"SELECT COUNT(*) FROM data.account_transactions",
		).Scan(&viewCount)
		is.NoErr(err)         // Should query the view without error
		is.True(viewCount > 0) // Should have at least one row in the view
	})
}
