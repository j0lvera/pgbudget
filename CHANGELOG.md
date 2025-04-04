# Changelog

All notable changes to pgbudget will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2023-04-XX

### Added
- Initial release of pgbudget
- Core database schema with ledgers, accounts, and transactions tables
- Double-entry accounting system for zero-sum budgeting
- API functions for common operations:
  - Creating accounts and categories
  - Recording income and expenses
  - Assigning money to budget categories
  - Viewing budget status and account transactions
- Automatic creation of special accounts (Income, Off-budget, Unassigned)
- Comprehensive test suite
- Detailed documentation and usage examples
