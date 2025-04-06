# Changelog

All notable changes to pgbudget will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2025-04-05

### Added
- Added function to calculate a balance on demand (#16)
- Added balance table and get transactions function (account view) (#17)
- Added contributing guidelines and licensing information

### Changed
- Updated changelog links and fixed version file

## [0.1.4] - 2025-04-04

### Changed
- Refactored: Moved pgcontainer to its own package for better organization
- Updated README with detailed information about bigint amount representation
- Improved documentation with clearer examples and usage instructions
- Removed redundant example transaction query from README

### Added
- Added comprehensive database amount representation details to documentation
- Added preparation for future 1.0.0 release

## [0.1.3] - 2025-04-01

### Added
- Added account view for easier transaction querying

## [0.1.2] - 2025-04-01

### Added
- Added account functions for better account management

## [0.1.1] - 2025-04-01

### Added
- Added category functions for budget management

## [0.1.0] - 2025-03-31

### Added
- Initial release with core functionality
- Refactored migrations to remove duplicate find_category function

[unreleased]: https://github.com/j0lvera/pgbudget/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/j0lvera/pgbudget/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/j0lvera/pgbudget/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/j0lvera/pgbudget/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/j0lvera/pgbudget/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/j0lvera/pgbudget/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/j0lvera/pgbudget/releases/tag/v0.1.0
