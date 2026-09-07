## [Unreleased]

### Security

- Row-level security: the system bypass is no longer a parameter of `super_auth_become()`. It moved to a separate function, `super_auth_system()`, whose `EXECUTE` privilege `enable` revokes from `PUBLIC`, so the right to bypass every policy is granted per role (`GRANT EXECUTE ON FUNCTION super_auth_system() TO <role>`) instead of coming with the right to assert an identity. `SuperAuth.as(user)` calls it for users whose `system?` is true. Both functions now raise if the calling role is a superuser or has `BYPASSRLS`, because Postgres exempts those roles from row security and the assertion would protect nothing. Breaking for clients that call the SQL directly: `super_auth_become(...)` takes three arguments and the four-argument overload is dropped on the next `enable`; roles that bypass need the grant above.

### Changed

- `SuperAuth::RLS.enable` grants `SELECT` on `super_auth_authorizations` and `super_auth_users` to `PUBLIC`, so a runtime role needs privileges on the application's tables and nothing else; `SuperAuth::RLS.grant_system(role)` hands out the bypass without hand-written SQL. `system?` on both user models is now a read-only lookup (`.system` still creates the row), so passing SuperAuth user records to `SuperAuth.as` never needs `INSERT`.

## [0.4.0] - 2026-09-02

### Security

- Fix: path strategy 1 (users <-> groups <-> roles <-> permissions <-> resources) granted every role held by any group to the members of every group that held a role. `SuperAuth::Edge.users_groups_roles_permissions_resources` built one set of all role-holding groups and one set of all group-held roles and cross-joined them with nothing correlating a group to its own role. The role lookup is now joined through the member's own group ancestry, so a role attached to one group never reaches members of an unrelated group. Affects `SuperAuth::Edge.authorizations` and anything compiled from it (`SuperAuth::ActiveRecord::Authorization.compile!`); recompile authorizations after upgrading.

### Added

- Postgres row-level security enforcement (`SuperAuth::RLS`, `rails g super_auth:rls Model ...`). Identity is anchored to the transaction by the `super_auth_become()` SQL function, exposed in Ruby as `SuperAuth.as(user) { ... }`, so non-Ruby clients get the same enforcement.
- Permission-gated subclass loading: a `ByCurrentUser` subclass is its own resource type, so privileged methods can live on a subclass whose access must be granted explicitly. A grant on the base class does not flow down.
- `SuperAuth.external_id_type` types the external id columns at install time instead of casting at query time.

### Changed

- Relicensed from MIT to GPL-2.0.
- Path strategies 1, 2 and 3 join group ancestry and role subtrees on integer pairs from two new recursive CTEs (`Group.ancestor_pairs`, `Role.descendant_pairs`) instead of LIKE-matching ids inside the comma-separated path strings, which no planner can index. Output is unchanged. On a 10,000-user graph the full `authorizations` union went from 10.4 s to 2.5 s on Postgres 16; on MySQL 8 a 500-user graph went from 9.9 s to 0.08 s, and on SQLite strategy 1 alone went from over 400 s to 0.01 s.

### Fixed

- MySQL 8 support. `SuperAuth::Edge.authorizations` raised "Illegal mix of collations for operation 'UNION'" whenever the connection collation differed from the table collation, which it does under ActiveRecord's defaults, so `compile!` could never run on MySQL. The recursive tree CTEs typed their path columns from the anchor row, so any `group_path` or `role_path` over 11 characters, or name path over 255, failed with "Data too long". Migration 8 no longer adds edge indexes on MySQL, where InnoDB already indexes foreign keys and refuses to drop them, which had broken `uninstall_migrations`. CI now runs the suite against real MySQL instead of silently falling back to SQLite.

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
