## [Unreleased]

## [0.7.0] - 2026-09-07

### Added

- `super_auth_resources.super_auth_label`, a nullable column holding the human name of the application record a resource node points at, so the editor can render "Gulf War presumptive" where it rendered `Claim#3a00b6fa-2998-41ba-953f-a3b0de1876b3`. The label is stored rather than resolved at render time for three reasons: the editor reads bare Sequel models with no association to the application, `super_auth-editor` serves the same UI against a bare `SUPER_AUTH_DATABASE_URL` with no application loaded at all, and RLS makes exactly the largest protected resource types unreadable without an asserted identity — a live lookup would return empty labels for those and full labels for everything else, which reads as data rather than as a missing permission. The column carries the prefix for the same reason the opt-in method does: `label` is a name applications want for themselves. Migration 10 in both `db/migrate/` and `db/migrate_activerecord/`.
- `SuperAuth.label_for(record)` derives that name by convention rather than configuration: `super_auth_label` if the model defines it, then `name`, then `title`. Never `to_s` — the label sits where `Type#id` otherwise renders, and `#<Claim:0x000055…>` is worse than the id it would replace.
- `SuperAuth::ActiveRecord::Resource` derives its label on save, so a host that already syncs resource nodes gets labels with no extra wiring, and `#refresh_label!` re-derives it after the application record is renamed, which does not write the node. A nil derivation never overwrites a stored label: RLS blanking the record, an `external_type` naming a class this process has not loaded, and a type-level row (`external_id IS NULL`) all derive nil, and none of them means the record has no name.
- The editor renders the label in the slot that held `Type#id`, demoting `Type#id` to the tooltip, and falls back to today's rendering for a node without one. Its per-box filter now matches everything a row carries — name, label, `external_type` and `external_id` — so a pasted uuid finds its node, which it never did before: the filter only ever looked at `name`.
- `rake super_auth:labels:backfill` labels existing rows and repairs drift. It asserts the system identity where RLS is installed, because the application tables it reads are the ones RLS protects — run without an identity it would derive nil for the rows that matter most and report success.

A stored label is a snapshot. It drifts between the application record being renamed and the next `refresh_label!` or backfill, and that is the trade: a stale or missing label degrades to the `Type#id` the editor rendered before, never to something wrong. `super_auth_users.name` has always been a denormalized label of the same kind and never refreshes at all, so this is the existing idea finished rather than a new one.

Users are out of scope: `super_auth_users.name` already carries a human name, so user nodes already read as "Jonathan Frias" in the editor. Groups, roles and permissions encode their application link in host-specific name conventions and are a separate job.

## [0.6.0] - 2026-09-07

### Added

- `SuperAuth::RLS.assert(user)` asserts the database identity in the transaction the caller already holds and opens nothing: the `SELECT super_auth_become(...)` half of the SQL contract, or `super_auth_system()` for a system user. For code that changes user mid-transaction or manages its own transaction; `SuperAuth.as` is now this plus a transaction plus restore.
- `SuperAuth::RLS.installed?` reports whether `enable` has run on the database, so an application that degrades when RLS is absent no longer probes for the SQL functions by signature. A probe written against one signature returns false when the signature changes and turns row-level security off with a green suite, which is what a 0.4.0 probe does against 0.5.0.

### Changed

- `SuperAuth.as` assigns `SuperAuth.current_user` inside the transaction, after the database identity is asserted, so an application that hooks the writer to re-assert does so on the transaction's connection instead of once outside it and once in.

### Removed

- `on_error:` on `SuperAuth.as` and `SuperAuth::RLS.as`, added in 0.5.0. Whether a write survives the block raising is the caller's decision, not the identity wrapper's: rescue inside the block to keep it, let the exception out to roll it back. `as` has one control-flow path again.

## [0.5.0] - 2026-09-07

### Security

- Row-level security: the system bypass is no longer a parameter of `super_auth_become()`. It moved to a separate function, `super_auth_system()`, whose `EXECUTE` privilege `enable` revokes from `PUBLIC`, so the right to bypass every policy is granted per role (`GRANT EXECUTE ON FUNCTION super_auth_system() TO <role>`) instead of coming with the right to assert an identity. `SuperAuth.as(user)` calls it for users whose `system?` is true. Both functions now raise if the calling role is a superuser or has `BYPASSRLS`, because Postgres exempts those roles from row security and the assertion would protect nothing. Breaking for clients that call the SQL directly: `super_auth_become(...)` takes three arguments and the four-argument overload is dropped on the next `enable`; roles that bypass need the grant above.

### Added

- A graph editor, Rails-free, shipped as a mountable Rack app (`SuperAuth::Editor`, `require "super_auth/editor"`) and a command (`super_auth-editor`) that serves it on loopback against `SUPER_AUTH_DATABASE_URL`, with `--migrate` and `--seed` as explicit, opt-in steps. Five boxes with client-side traversal, node and edge CRUD, and a Recompile button. It has no authentication of its own: mount it inside yours. Writes must be JSON, only the eight edge kinds the path strategies read can be created, and the command rejects foreign `Host` headers.
- `SuperAuth::Authorization.compile!` for applications without ActiveRecord, and `POST /api/compile` in the editor. Runtime enforcement reads only the compiled table, so every graph edit is inert until it runs.

### Fixed

- `ByCurrentUser` now recognises a Sequel `SuperAuth::User` as an internal user and matches it on `user_id`, as the RLS policies already did; before, it was treated as an external object and silently saw nothing. Both layers share `SuperAuth.internal_user?`.

### Removed

- The d3 graph visualizer: `SuperAuth::GraphController`, its view, its JSON API (`/graph/data`, `/graph/authorize`, `/graph/orphaned`, `/graph/compile_authorizations`, and the `/graph/*` create and delete routes), `visualization.html`, and `VISUALIZATION.md`. `mount SuperAuth::Engine => "/super_auth"` now serves the graph editor at that path; it has no authentication of its own, so mount it inside yours. Anything that called the old JSON routes must move to the editor's API or to the models.

### Changed

- `SuperAuth.as(user)` now carries both identities: it sets `SuperAuth.current_user` (read by the `ByCurrentUser` scope) for the block as well as asserting the database identity (read by the RLS policies), and restores both on the way out, on return, on raise, and when nested. `SuperAuth::RLS.as` stays the pure SQL-contract wrapper and now restores the enclosing database identity when it is nested inside a transaction, so an inner block can no longer leave the outer one running as its user. Inside a transaction the caller opened, `as` joins it. One option replaces the wrapper an application used to need: `auto_savepoint: true` makes every nested transaction a savepoint (the ActiveRecord bridge turns it into `joinable: false`), so a save inside the block commits on its own and its `after_commit` hooks fire then. Other keyword options pass through to Sequel's `transaction`. Behaviour change: `SuperAuth.as(nil)` runs the block with `current_user = nil`, so apps with `missing_user_behavior = :raise` now raise on scoped queries inside an anonymous block instead of inheriting whatever the thread-local held before. Clients that probe for the identity function must look for `super_auth_become(text, text, text)`; the four-argument signature is gone (see Security above).
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
