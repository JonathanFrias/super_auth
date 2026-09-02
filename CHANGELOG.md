## [Unreleased]

## [0.4.0] - 2026-09-02

### Added

- Postgres row-level security enforcement (`SuperAuth::RLS`, `rails g super_auth:rls Model ...`). Identity is anchored to the transaction by the `super_auth_become()` SQL function, exposed in Ruby as `SuperAuth.as(user) { ... }`, so non-Ruby clients get the same enforcement.
- Permission-gated subclass loading: a `ByCurrentUser` subclass is its own resource type, so privileged methods can live on a subclass whose access must be granted explicitly. A grant on the base class does not flow down.
- `SuperAuth.external_id_type` types the external id columns at install time instead of casting at query time.

### Changed

- Relicensed from MIT to GPL-2.0.

## [0.3.3] - 2026-04-29

- Fix: detect PostgreSQL/SQLite/Mysql2 adapter subclasses (e.g. PostGIS, Makara) when bootstrapping the Sequel connection from ActiveRecord. Previously only the exact stock adapter classes were recognized, leaving `SuperAuth.db` unset for apps using a subclassed adapter.

## [0.3.2] - 2026-03-10

- Feature: Add `SuperAuth.missing_user_behavior` configuration option
  - `:none` (default) — returns empty result set when `current_user` is blank (existing behavior)
  - `:raise` — raises `SuperAuth::Error` when `current_user` is blank (fail-fast for apps that always require authentication)

## [0.3.1] - 2026-03-10

- Refactor: move authorization compilation logic into Authorization model (`compile!` and `from_graph` class methods)

## [0.3.0]

- Fix: ByCurrentUser mixin — correct subquery column, add admin wildcard, remove dead code
- Remove unused tests

## [0.2.0]

- Version bump with various improvements

## [0.1.0] - 2023-12-09

- Initial release
