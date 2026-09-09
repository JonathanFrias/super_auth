## [Unreleased]

## [0.8.0] - 2026-09-09

### Added

- `super_auth_resources.parent_id`, a nullable self-referencing key, so resource nodes nest the way groups and roles do. `SuperAuth::Resource` includes `SuperAuth::Nestable` and gains the same tree API: `parent`, `children`, `ancestors`, `descendants` (and the `_dataset` variants), `roots`, `trees`, `ancestor_pairs` and `descendant_pairs`. A node with neither `external_type` nor `external_id` is a container: one per folder, project, tenant or whatever the application nests records under, with the records registered beneath it. Migration 11 in both `db/migrate/` and `db/migrate_activerecord/`.
- A grant on a resource node reaches the node and every node under it, through all five path strategies. The last hop of each strategy is a join through `SuperAuth::Resource.descendant_pairs` where it was a primary-key join, so the subtree is expanded at compile time and `super_auth_authorizations` gains no columns: `ByCurrentUser` and the row-level security policy are untouched, still read only `resource_external_type` and `resource_external_id` from the compiled table, and cannot tell a row compiled through a container from one granted directly. No recompile is needed after upgrading. On a flat graph the pairs relation is the identity and the compiled rows are exactly what 0.7.0 produced.
- The pairs CTE is anchored on the resource ids that appear in `super_auth_edges.resource_id` (`descendant_pairs(of:)`, wrapped by `SuperAuth::Edge.resource_subtrees`), so the walk is sized by the grants rather than by the table. Groups and roles are few and the whole table is cheap; resources are one row per protected record, and an unanchored CTE materialises every pair of the whole table once per strategy that joins it. Measured at 300,000 resources: MySQL 8 went from 27 s per strategy unanchored to 0.025 s anchored, Postgres from 0.3–0.6 s to 0.008 s.
- No `resource_path` or `resource_name_path` columns, a deliberate asymmetry with groups and roles. A row compiled through a container carries the descendant node's own `resource_id`, `resource_name`, `resource_external_type` and `resource_external_id` — the record the grant reaches, which is all runtime reads. "Granted through which container" is answered by the graph (`parent_id`, `parent`, `children`) and by the editor, not by the compiled table; the trade is that an audit of the compiled table alone no longer sees the container an edge was drawn to.
- Containment is not inheritance. Because the compiled row copies the descendant's own `external_type`, the permission-gated subclass rule holds — a `"Post"` grant still says nothing about `"Post::PostPublishPermission"` — but a capability node registered *under* its base-class node is a descendant of it and receives every grant on the base. Register capability nodes as siblings of their base-class nodes, or in a container beside them, never as their children. A documentation rule, not a check: the gem cannot tell a capability subclass from any other type name.
- The editor renders resources as a tree, creates containers (a resource node with no external link, at the root or under a chosen parent), and refuses two things with a 422 and the reason: creating a node under a wildcard parent, and a compile refused by the guard below (in 0.7.0 a resource create with any `parent_id` was refused as "resource records cannot have a parent"; that message no longer occurs for resources). Application code registers records under a container by saving a node with `parent_id`; there is no re-parent route yet.
- `SuperAuth.deprecator`, where the gem's deprecation warnings go. An `ActiveSupport::Deprecation` when ActiveSupport is loaded, which the railtie registers as `app.deprecators[:super_auth]` so `config.active_support.deprecation` and `report_deprecations` apply on Rails 7.1+; otherwise a stand-in with the same `warn` and `silenced=`.

### Removed

- The editor's second Users box. The bottom row drew Resources beside a duplicate of the Users box from the top row — same rows, shared selection — with nothing saying why; Resources now spans the bottom row and users are listed once.

### Deprecated

- Type-level (wildcard) resource nodes: a node with an `external_type` and no `external_id`, which at runtime means every record of that type, present and future (`ByCurrentUser`'s type-level branch; the policy's `resource_external_id IS NULL OR` clause). They keep working, unchanged, and no removal version is promised. What changes is at compile time. `compile!` (both twins) now warns once per compile through `SuperAuth.deprecator`, naming up to ten of them, and refuses a wildcard that has a parent or children, raising `SuperAuth::Error` ("Wildcard resource nodes must be flat, but wildcard node(s) 12, 15 have a parent or children. …") before the compiled table is touched, so the previous rows stay. That is the one shape the tree cannot hold: nested under a container, a wildcard would compile to a `(type, NULL)` row reachable through every ancestor's grants, one edge to a container silently granting every record of a type; and nodes under a wildcard are unreachable except through a grant that already covers them. The rule is that wildcard nodes are flat: at the root, with no children, or given an `external_id`. The guard and the compile are two statements, so the subtree join carries the same rule as a predicate: a `(type, NULL)` row is only ever the node a grant named, never one reached through a parent, whatever a concurrent write commits between the two under `READ COMMITTED`. The guard is the loud error; the predicate is the guarantee.
- A container is not a replacement for a wildcard on a table under row-level security, and the wildcard remains the only way to authorize INSERT there this release. The policy is `FOR ALL` with no `WITH CHECK`, so Postgres reuses `USING` for new rows, and a per-record row can only match an id the application has already registered and compiled. Moving an RLS-protected type from a wildcard to a container loses INSERT, needs a resource node saved and a full recompile for every new record before it is visible, and needs a role that can write the gem's tables, which `enable` grants `SELECT` on only. The successor is a grant on a parent record — `SuperAuth::RLS.enable(:documents, resource_type: "Document", parent: { column: :folder_id, resource_type: "Folder" })`, with the policy matching per record on `t.id` or per record on the parent column, and a `ByCurrentUser` mirror — planned for the next release, which is when the wildcard stops being needed. Until then a wildcard on an RLS host is the supported shape and the warning is a notice, not a fault.

### Fixed

- `compile!` turns Postgres JIT off for its own transaction (`SET LOCAL jit = off`). Postgres was JIT-compiling the five-strategy union's expressions on every compile — 358 LLVM functions in 0.7.0, 539 with the new subtree joins — spending 1.6 s (0.7.0) to 2.2 s (0.8.0) in LLVM optimisation and emission for a query that executes in about 10 ms; the whole of the "compile is slow on Postgres" cost was JIT, on any graph size. `SET LOCAL` dies with the transaction, so nothing reaches the pooled connection. `SuperAuth::Edge.authorizations` called on its own is unchanged.
- `compile!` no longer runs forever on a `parent_id` cycle. The two pair CTEs in `SuperAuth::Nestable` (`ancestor_pairs`, `descendant_pairs`) recurse with `UNION` instead of `UNION ALL`: the pair relation is finite, so `UNION` stops the first time a step produces nothing new, which on a cycle is the first time round, where `UNION ALL` re-derived the same pairs without end. MySQL aborted after 1001 iterations (`cte_max_recursion_depth`); Postgres and SQLite looped until killed. Output is unchanged on a valid tree, where no step repeats a pair. The path-building tree CTEs the strategies join for group and role path columns are anchored on the roots and walk downward, so they never enter a cycle: a cyclic group or role component is unreachable from any root and every grant that passes through it compiles to no rows, silently, fail-closed. A check against cycles at write time remains open.

### Upgrade notes

- Run migration 11 before deploying code that saves resource nodes or compiles: `SuperAuth::Resource` now reads `parent_id`, so `compile!` on an un-migrated schema fails with a missing-column error. In Rails, `rails super_auth:install:migrations` copies the new migration into the app and `rails db:migrate` runs it — the engine-scoped task; `railties:install:migrations` also works but sweeps in every mounted engine's pending migrations at once — the engine points the install task at `db/migrate_activerecord` but does not run its migrations on its own, which the install generator's notes used to claim and now do not. Without Rails, `SuperAuth.install_migrations` or `super_auth-editor --migrate`; `rake super_auth:migrate` exists only inside a Rails app (its tasks depend on `:environment`).
- No recompile: the compiled table has the same columns and, on a flat graph, the same rows.
- On a database that has been compiling incrementally — a per-user recompute that reinserts rows without a full clear — the first full `compile!` on 0.8.0 can legitimately drop rows: stale duplicates the incremental path accumulated, not grants. The check that tells the two apart is `compile!` on 0.7.0 against `compile!` on 0.8.0 over the same graph, which give the same count; a row count taken before the upgrade and after the first compile does not, and reads as 0.8.0 having eaten grants.
- With wildcard nodes in the graph, every compile prints one deprecation line naming them. Silence it with the Rails deprecation config — the deprecator is `app.deprecators[:super_auth]`, so `config.active_support.deprecation = :silence` and `config.active_support.report_deprecations = false` both apply — or with `SuperAuth.deprecator.silenced = true`.
- Compiled-table growth: a grant on a container compiles one row per descendant per path, and `compile!` inserts row by row, so a container over many records lengthens every compile in proportion. A single `INSERT ... SELECT` is the tracked follow-up.

## [0.7.0] - 2026-09-07

### Fixed

- The editor's Groups and Roles boxes drew a flat list ordered by name and faked the hierarchy with indentation, so a child appeared nested under whichever unrelated node happened to sort directly above it — a group named `org:451ed5a8…` sorts between "Lawyers" and "Organizations" and was drawn under Lawyers, while its real parent rendered below its own child. Group grants flow to members of descendant groups, so "which parent does this hang under" is the question the editor is opened to answer, and it was answering it wrong. `/api/graph` now returns nested types ordered by ancestor name path, so each child follows its own parent with siblings alphabetical among themselves. Display only: no `parent_id` changes, and the client's `depthOf` is untouched. The order stays total for a broken tree — a dangling `parent_id` sorts as a root, and a parent cycle terminates rather than hanging the sort.

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
