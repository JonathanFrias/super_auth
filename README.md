# SuperAuth

[![Build Status](https://github.com/JonathanFrias/super_auth/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/JonathanFrias/super_auth/actions)

Super auth is a turn-key authorization engine that makes unauthorized access unrepresentable — enforced in your database, so the same rules protect every client, in any language, that touches your data. **Stop writing authorization tests; enforce access with confidence.**

The intent is to centralize authorization for one application or many, in any language. If you look at the [OWASP top vulnerability](https://owasp.org/Top10/A01_2021-Broken_Access_Control/), broken
access control is the NUMBER 1 most common security risk in modern applications today. super_auth provides an authorization model that lets you de-risk your application, solving this issue once, confidently.


## Installation

SuperAuth enforces authorization in the database, so any language can participate. The reference client is the Ruby gem:

    gem "super_auth"

## Supported databases

PostgreSQL 13+, MySQL 8.0+, and SQLite 3.44+. The group, role and resource trees are
recursive CTEs and the path columns use `concat()`, which sets those floors. CI runs the full
suite against each of the three. Row-level security is Postgres only.

## Docs

How `super_auth` stacks up against other authentication strategies:
[Do you really understand Authorization](https://dev.to/jonathanfrias/do-you-really-understand-authorization-1o5d)

## Graph editor

A Rails-free editor for the authorization graph: five boxes (groups, roles, users,
permissions, resources), of which groups, roles and resources are drawn as trees; click
any record to trace what it can reach and what reaches it; connect two records to draw
an edge; create records, including a resource container under a chosen parent; delete
records and edges; recompile. The editor makes containers, not application records:
your code registers a record under a container by saving a resource node with
`parent_id`, and a grant on the container reaches everything under it. It ships in the
gem as a Rack app and a command.

```bash
gem install super_auth rackup webrick        # any Rack server works; puma too
SUPER_AUTH_DATABASE_URL=postgres://user:password@localhost/app_development super_auth-editor
```

Then open http://127.0.0.1:4666. Options: `--host` (default `127.0.0.1`), `--port`
(default `4666`), `--migrate` (run the gem's Sequel migrations first, for a database that
has none), `--seed` (replace the whole graph with a sample company, destructive).

> ⚠️ **The editor has no authentication.** Anyone who can reach it can rewrite the graph.
> The command binds to loopback and rejects requests whose `Host` header is not
> localhost. When you mount the app in your own server, put your own authentication in
> front of it, as below.

In Rails the engine serves it. Mount the engine inside your own authentication:

```ruby
# config/routes.rb
authenticate :admin do                          # Devise; or a constraints block
  mount SuperAuth::Engine => "/super_auth"
end
```

Or mount the app itself anywhere: `require "super_auth/editor"` and
`mount SuperAuth::Editor => "/wherever"`, again inside your authentication.

Mount it in any Rack app:

```ruby
# config.ru
SuperAuth.db = Sequel.connect(ENV.fetch("SUPER_AUTH_DATABASE_URL"))
SuperAuth.load
map "/super_auth/editor" do
  use Rack::Auth::Basic { |user, password| user == "admin" && password == ENV.fetch("EDITOR_PASSWORD") }
  run SuperAuth::Editor
end
```

Edits change the graph, not runtime access: `ByCurrentUser` and the row-level security
policies read the compiled `super_auth_authorizations` table. The strip at the top shows
that table's row count, and **Recompile** runs `SuperAuth::Authorization.compile!`
(`POST /api/compile`). The API is small and JSON: `GET /api/graph`,
`POST /api/nodes/:type`, `DELETE /api/nodes/:type/:id`, `POST /api/edges`,
`DELETE /api/edges/:id`, `POST /api/compile`. Writes must be `application/json`, and
the editor only creates edges of the eight kinds the path strategies read.

## Postgres Row-Level Security (optional)

The `ByCurrentUser` scope enforces authorization at the ORM layer. On Postgres you can
additionally enforce the same reach inside the database itself, so raw SQL, `unscoped`,
background jobs, and any other client on the same database are subject to it too —
unauthorized rows become invisible at the connection level. Enforcement is pure SQL:
participating apps don't load this gem, or Ruby, at all. The gem's role is
administrative — define the graph, compile authorizations, enable the policies — which
is what makes super_auth usable as a central authorization service for apps in any
language.

What the database enforces is *tenancy*, not capability. Authorization protection will
always be a combination of the language client ORM plus the super_auth database. The
RLS is just a portable way to start the transition to cover new languages and provide
some base authorization support to future apps. The policy decides which rows an
identity may touch at all; which of those it may write is the application's decision,
in code, in every language that writes.

**Optional means optional.** Nothing outside this section needs it. The tables,
`ByCurrentUser`, `permission_gated`, `parent:` grants and the graph editor all work on
SQLite and MySQL, and on Postgres with no policy enabled — `rails generate
super_auth:rls` is a separate generator you run when you want the second layer, and
until you do there is nothing to configure and nothing to keep current. `SuperAuth.as`
is the same call either way: on a database with no policies it sets `current_user` and
runs the block, and once `enable` has run it also opens the transaction and asserts the
database identity. So the ORM layer is deployable first and RLS is a later migration,
not a rewrite. `SuperAuth.rls?` reports which mode you are in.

### The contract (any language)

Identity is asserted per transaction by calling the `super_auth_become` function that
`SuperAuth::RLS.enable` installs:

```sql
BEGIN;
SELECT super_auth_become(user_external_id => '42', user_external_type => 'AppUser');
-- run normal queries; rows the user isn't authorized for don't exist --
COMMIT;  -- identity dies with the transaction; there is nothing to clear
```

For a user managed inside super_auth, pass `user_id => '7'` instead.

System context, which bypasses the policies (migrations, seeds, admin jobs), is a
separate function, so the right to bypass is granted per role rather than coming with
the right to assert an identity:

```sql
BEGIN;
SELECT super_auth_system();
-- every protected row is visible and writable --
COMMIT;
```

`enable` revokes `EXECUTE` on `super_auth_system()` from `PUBLIC`; a role without an
explicit grant (`SuperAuth::RLS.grant_system(role)`) gets `permission denied`. Both
functions raise if the calling role is a superuser or has `BYPASSRLS`: Postgres exempts
those roles from every policy, so the assertion would protect nothing while looking
like it does.

The assertion is anchored to the calling transaction: `super_auth_become` sets
transaction-local identity settings plus a stamp of the current transaction id, and
every policy requires a stamp from the current transaction. Outside a transaction the
settings have already reverted, and identity smuggled in as session settings carries a
dead transaction's stamp — either way queries return no rows and writes are rejected.
Misuse fails closed, and the scheme works unchanged behind transaction-pooling proxies
like pgbouncer, because a transaction is exactly what they keep on one server
connection.

#### What the policy admits

Every protected table carries one policy, `super_auth`, `FOR ALL`. Its `USING` is the
transaction stamp AND (system context OR one step per entry of the table's *reach*):
the columns through which a compiled authorization reaches a row, each with the types
whose rows admit through it. The reach is declared on the policy and again on the model,
both through `SuperAuth::Reach.normalize`, and `current?` is what confirms the two agree
(see [Permission-Gated Models](#permission-gated-models)):

```ruby
SuperAuth::RLS.enable(:claims,
  resource_type: "Claim",
  parent: { column: :organization_id, resource_type: ["Organization::Member", "Organization::Admin"] })
# reach: { id: ["Claim"], organization_id: ["Organization::Member", "Organization::Admin"] }
```

installs this, verbatim except that `<holder>` is spelled out below:

```sql
CREATE POLICY super_auth ON "claims"
USING (
  current_setting('super_auth.xid', true) = pg_current_xact_id()::text
  AND (
    COALESCE(current_setting('super_auth.system', true), '') = 'true'
    OR EXISTS (SELECT 1 FROM super_auth_authorizations a
               WHERE a.resource_external_type IN ('Claim') AND a.resource_external_id IS NULL AND <holder>)
    OR "claims"."id" IN (SELECT a.resource_external_id FROM super_auth_authorizations a
               WHERE a.resource_external_type IN ('Claim') AND a.resource_external_id IS NOT NULL AND <holder>)
    OR "claims"."organization_id" IN (SELECT a.resource_external_id FROM super_auth_authorizations a
               WHERE a.resource_external_type IN ('Organization::Member', 'Organization::Admin')
                 AND a.resource_external_id IS NOT NULL AND <holder>)
  )
)
```

Each subquery is written out as the `UNION ALL` of its two `<holder>` halves —
`a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')` for a user
managed inside super_auth, and `a.user_external_id::text =
NULLIF(current_setting('super_auth.user_external_id', true), '') AND a.user_external_type =
NULLIF(current_setting('super_auth.user_external_type', true), '')` for an application
user — so each half can walk an index of its own. The column is cast to text and never the
setting to the column's type, so a malformed identity is no rows rather than an error that
aborts the transaction, and a cast on a column defeats a plain btree: migration 12 indexes
the two expressions the policy actually writes, `(user_id::text)` on every Postgres host
and `(user_external_id::text)` on the hosts where `external_id_type` is not a text type —
where it is, `idx_sa_auth_by_current_user` already answers the cast as a seek. Both halves
are emitted whatever kind of identity you assert, so every install reads through the
`user_id` half too, which is why that index is not optional. Three kinds of step, in
this order:

- **Type-level.** A compiled row for one of the table's own types with
  `resource_external_id` NULL admits every row of the table, present and future. A
  supported, permanent primitive — "this principal may act on every record of this
  type" has no cheaper spelling — and it is always emitted unless `enable` is given
  `wildcard: false`, an explicit opt-out for a table whose types are never granted
  type-level; a `(type, NULL)` row then admits nothing there.
- **Per record** (`id`). The row's own id is among the ids the holder's rows for the
  table's own types name.
- **Parent** (one per `parent:` column, in the order declared). The value in the
  column is among the ids the holder's rows for the column's types name: the row's
  tenancy, read off the row itself, so there is no node per row and nothing to
  recompile when a row is created or moves.

Nothing in the expression is correlated with the outer row, so Postgres evaluates each
step once per query — an InitPlan and hashed SubPlans — instead of once per row: 2.6 ms
on 8,007 claims against a holder with thousands of rows, where a per-row form is
seconds. `INSERT` and `UPDATE` are gated by the same expression: the policy has no
`WITH CHECK`, so Postgres reuses `USING` for the new row, and a create is admitted by a
type-level grant on the table's type, by a parent grant for the value the new row
carries in a parent column, or by system context.

The reach and a policy version are recorded as JSON in the policy's comment —
`{"super_auth":2,"reach":{"id":["Claim"],"organization_id":["Organization::Member","Organization::Admin"]},"wildcard":true}`
— which any client can read back with `obj_description(oid, 'pg_policy')`; the Ruby
readers are under [Keeping the policy current](#keeping-the-policy-current).

#### What the policy does not decide

1. **Tenancy, not capability.** The policy is the tenancy boundary: organization A
   never reads organization B's rows, enforced on the row's own column. Which of the
   admitted tenants may write — viewer against writer inside one organization — is the
   application's, in code. The policy is `FOR ALL` and gates no verb: a holder of a read
   tier passes it for `UPDATE` and `DELETE` at the database. `DELETE` in particular is
   gated by `USING` alone, so a read-tier holder's unfiltered `DELETE` removes every row
   of their tenancy and reports 0 rows for everything else, without an error. Known,
   accepted, and by design: RLS is the portable base, not the whole of authorization.
2. **A parent type must be a capability type nobody else is granted.** Key the column on
   `Organization::Member`, never on bare `Organization`: a per-record `Organization` node
   is what a grant of *any* kind on the organization reaches, and it would admit every
   claim to whoever holds it for whatever reason. Names do not say which kind a type is.
   `Claim::Admin` is platform-only — force a status, wipe review data, actions even the
   claim's owner may not take — granted type-level to the admin tier and per record to
   nobody, and it declares **no parent, ever**; `Organization::Admin` is a per-organization
   capability node organization admins are supposed to hold, and a legitimate parent
   type. Same suffix, opposite meanings: pairing `Claim::Admin` with `Organization::Admin`
   "for symmetry" would let every organization admin force status on their own
   organization's claims. The Ruby side by side is under
   [Permission-Gated Models](#permission-gated-models).
3. **Every column lists every tier's parent type**, because the policy must never be
   narrower than any tier's ORM scope over the same table. `Claim` keyed on
   `Organization::Member` for readers and `Claim::Writable` on `Organization::CaseWriter`
   in the ORM means the policy lists both under `organization_id` — a holder of one
   without the other exists — or the ORM shows a row the database hides, which fails
   closed and reads as a permissions bug. The gem cannot check this: the policy sees no
   Ruby classes. It is yours.
4. **Parents do not chain.** A grant on the organization reaches a claim through
   `claims.organization_id` and stops. A medium that belongs to a claim is reached
   through a column of its own on `media`, declared on `media`, not through `claims`.
5. **No row can be created through ActiveRecord that its creator cannot immediately
   read.** ActiveRecord always emits `INSERT ... RETURNING` on Postgres, and the returned
   row must pass `USING`. A `WITH CHECK` could only narrow `USING`, never widen it. This is
   why a node minted in `after_create_commit` can never authorize its own record's
   `INSERT`: the row has to pass before the callback runs. What admits a create is listed
   above; it is never "the node this create will make".
6. **A create with no parent value cannot be authorized by the column step.** `col = NULL`
   is never true. A row whose parent column is NULL is admitted by a type-level grant, a
   per-record row, or system context, and a new row has no per-record row yet. The escape
   hatch is system context around exactly that branch — `SuperAuth.as(SuperAuth::User.system) { ... }`,
   or `SuperAuth::RLS.assert(system_user)` inside the transaction you already hold — never
   SQL interpolated into a policy.
7. **A per-record holder may set the parent column to any value.** `USING` is reused as
   the check and a self-referencing check is not expressible, so a holder admitted by the
   row's own id may move it to an organization they do not hold; the client gates that
   column on write. Note the failure direction: with per-record nodes a wrong grant fails
   closed, with a tenancy column a wrong *value in the column* fails **open** — guard
   writes to it.
8. **The compiled table alone no longer answers "who can see X".** A row is admitted by a
   compiled row naming a *different* record, so the answer is a join through the
   protected table: `SuperAuth::RLS.explain(:claims, id)` for any client (it reads the
   comment, needs no model), `Claim.super_auth_explain(id)` in Ruby.
9. **A type-level row on a parent type admits nothing.** `(Organization::Member, NULL)` is
   not "every organization's claims": a column holds an id, and NULL equals none. Grant
   the table's own type type-level for that.
10. **`pg_current_xact_id()` cannot run on a hot standby** (pre-existing, unchanged): the
    stamp assigns a transaction id, which a read replica cannot do, so neither the
    assertion nor a protected query runs there.

### Setup (Rails)

**1. Match column types to your primary keys — before your first migration.**
The policies compare `super_auth_authorizations.resource_external_id` directly
against your tables' pks, and against every parent column, with no casting, so the
columns must share a type:

```ruby
# config/initializers/super_auth.rb
SuperAuth.setup do |config|
  config.external_id_type = :bigint   # Rails' default pk type; use :uuid, :string, ... to match yours
end
```

If super_auth is already migrated with the wrong type, alter the four external id
columns (`super_auth_users.external_id`, `super_auth_resources.external_id`,
`super_auth_authorizations.user_external_id`, `super_auth_authorizations.resource_external_id`)
in a migration of your own. `enable` checks, before any DDL, that every column the
policy will compare exists and shares the type family (both integer types, or both text
types), and names the table, the column, both types and this setting when one does not.

**2. Enable RLS on the tables you want protected:**

```bash
rails generate super_auth:rls Claim Invoice
rails db:migrate
```

This creates one migration calling `enable` per model, each followed by a commented
`parent:` line to fill in where the table carries a tenancy column:

```ruby
SuperAuth::RLS.enable(:claims, resource_type: "Claim")
# Tenancy, not capability: a parent grant admits every row whose column holds a granted record's id, so list every type that may touch the row at all and let the ORM decide who writes.
#   parent: { column: :organization_id, resource_type: ["Organization::Member"] }
```

You can also call `enable` directly for tables outside Rails. `resource_type` must match
the `resource_external_type` used in your authorization rows (the model's class name when
you use the AR integration, one entry per class that scopes the table); `parent:` is a
`{ column:, resource_type: }` Hash or an Array of them, the same shape the model's
`super_auth parent:` takes. The DDL runs in one transaction under `lock_timeout:` (default
`"5s"`) — `DROP` and `CREATE POLICY` take `ACCESS EXCLUSIVE`, and separately they left a
window with no policy on a live table — and joins the migration's transaction when there
is one. `enable` is idempotent and re-runnable on a protected table, which is how a
policy is changed.

**3. Connect as a role RLS applies to.** Superusers and `BYPASSRLS` roles skip
policies entirely, so the app must not connect as one (owning the tables is fine —
the policies use `FORCE ROW LEVEL SECURITY`); both identity functions refuse such a
role outright. `enable` grants every role what it needs on the gem's own tables
(`SELECT` on `super_auth_authorizations` and `super_auth_users`; `super_auth_become`
is executable by `PUBLIC`), so a runtime role needs privileges on your tables and
nothing else:

```sql
CREATE ROLE app_runtime LOGIN PASSWORD '...';
GRANT SELECT, INSERT, UPDATE, DELETE ON claims, invoices TO app_runtime;
```

The right to bypass the policies is separate. Grant it, from a migration or a
console, only to the roles that run migrations, seeds and admin jobs:

```ruby
SuperAuth::RLS.grant_system(:app_admin)  # GRANT EXECUTE ON FUNCTION super_auth_system() TO app_admin
```

To keep the gem's tables readable only by specific roles instead, `REVOKE SELECT ON
super_auth_authorizations, super_auth_users FROM PUBLIC` and grant per role; the
policies run as the querying role, so it must keep that `SELECT`.

> ⚠️ **This is the one step that, if skipped, silently disables all protection.**
> PostgreSQL *always* lets **superusers** and roles with the **`BYPASSRLS`** attribute
> bypass row-level security. `FORCE ROW LEVEL SECURITY` only subjects the table *owner*
> to the policies — it does **not** constrain a superuser. So if your app connects to
> Postgres as a superuser (the default in many local setups and some managed hosts), the
> policies apply to nobody and every row stays visible, while everything *looks* like it
> is working. Always connect as a dedicated non-superuser, non-`BYPASSRLS` role such as
> `app_runtime` above. `super_auth_become()` and `super_auth_system()` refuse to run for
> such a role, so a misconfigured connection fails on its first identity assertion
> instead of silently seeing everything.

**4. Wrap work in an identity assertion.** In Ruby:

```ruby
SuperAuth.as(current_user) do
  # every query in here is enforced by the database
end
```

`SuperAuth.as` sets `SuperAuth.current_user` for the block as well, so the
`ByCurrentUser` scope and the policies agree, and restores both on the way out, nested
calls included. It opens a transaction and calls `super_auth_become` for you, or joins
the transaction you are already in — use it in an `around_action` (or around a job) to
cover a whole request. `auto_savepoint: true` makes every nested transaction a
savepoint (ActiveRecord's `joinable: false`), so each save inside commits on its own
and its `after_commit` hooks fire then; other keyword options pass through to Sequel's
`transaction`. Whether a write survives the block raising is up to you: rescue inside
the block to keep it. Where there is no block to wrap, a transaction you already
manage or a change of user mid-request, `SuperAuth::RLS.assert(user)` asserts the
identity in the current transaction and nothing else, and `SuperAuth::RLS.installed?`
reports whether `enable` has run, so no application needs to know the SQL functions'
signatures. Non-Ruby apps use the SQL contract directly. Each policy checks
`super_auth_authorizations` with the same semantics as `ByCurrentUser`: a type-level
grant (`resource_external_id IS NULL`) admits every row of the type, a per-record row
matches on id, a parent row matches on the declared column. Any object with an `id`
works as the user, including SuperAuth's own user records. For a user whose `system?`
is true, `SuperAuth.as` calls `super_auth_system()` instead, so the connection's role
must have been given the bypass with `SuperAuth::RLS.grant_system`.

### Keeping the policy current

A gem upgrade changes nothing already in the database. The policy `enable` wrote stays
exactly as written until `enable` runs again, so a release that changes the policy
template — 0.9.0 did — or a model that gains a `parent:` needs `enable` re-run for that
table, in a migration, with the arguments it should now carry. A parent grant is
invisible to a policy that predates it: the holder sees nothing, fail closed, and it
reads as a permissions bug.

`enable` records `SuperAuth::RLS::POLICY_VERSION` and the reach in the policy's comment,
never `ALTER`s a policy, and drops every name it has ever given one before creating
`super_auth` (Postgres ORs permissive policies, so one left behind under an old name would
keep admitting rows). Two readers:

```ruby
SuperAuth::RLS.stale                                   # => [:claims]  tables whose policy predates this gem
SuperAuth::RLS.current?(:claims, resource_type: "Claim",
  parent: { column: :organization_id, resource_type: ["Organization::Member", "Organization::Admin"] })
# => true only if row security is enabled and forced, the comment matches these
#    arguments exactly, and the expression is not the 0.8.0 shape
SuperAuth::RLS.reach(:claims)                           # => { id: ["Claim"], organization_id: [...] }
```

Put `current?` in a test helper or a health check: it is what catches a deploy that
changed `parent:` in the model and not in the database, and `RENAME COLUMN`, which
rewrites the stored expression while the comment keeps the old column name. `installed?`
is unchanged and means only that the identity functions exist.

**Run `stale` first after any upgrade.** `current?` answers `false` for a table with no
policy of the gem's, or one whose row security is off or whose reach genuinely
disagrees — but a policy an *earlier* version of `enable` built makes it **raise**, with
the same message `reach` and `coverage` give: "the super_auth policy on claims was not
built by this version of enable (policy version 2); re-run `SuperAuth::RLS.enable`".
There is nothing to compare these arguments against on such a table, and a bare `false`
would say "your `parent:`/`wildcard:` arguments are wrong" about a database whose only
fault is that nobody re-ran `enable` — which is exactly the state `db:migrate` alone
leaves you in, since no migration re-runs it. It is also the expensive state to be in
unawares: the 0.8.0 policy is still installed and still correlated per row. `stale` asks
the same question across every table and never raises, so a health check that wants a
bare list has one.

### If you are still on 0.7.x or 0.8.0

The policy those releases installed is one `EXISTS` correlated on the outer row —
`(a.resource_external_id IS NULL OR a.resource_external_id = t.id) AND (internal OR
external)` — so its cost is paid once per row the statement touches, and what it scales
with is the number of **type-level** grants (`resource_external_id IS NULL`) on the types
you protect, not your record count. You cannot change the predicate without upgrading, so
measure yours before deciding anything:

```sql
SELECT count(*) AS total,
       count(*) FILTER (WHERE resource_external_id IS NULL) AS type_level
FROM super_auth_authorizations;

SELECT resource_external_type, count(*)
FROM super_auth_authorizations
WHERE resource_external_id IS NULL
GROUP BY 1 ORDER BY 2 DESC;
```

The breakdown is the number to read, not the total: the type-level step is type-scoped, so
a table protected as `Claim` pays for the `Claim` rows and not for 50,000 rows of an admin
type no policy reads. Take the count for each type you passed to `enable`. It counts
principals holding a type-level grant on a protected type, which for most designs is an
admin population and therefore bounded by staff rather than by customers; it is where a
host hands type-level grants on a protected type to ordinary users that it grows without a
ceiling.

The curve, measured on synthetic data — a uuid install, an 8,000-row protected table, one
`SELECT count(*)`: at ~1,000 type-level rows, 7.9–9.5 s; at 50,000, 121–141 s; at 150,000,
348–350 s. That last is 5.8 minutes for one `count(*)` over 8,000 rows. A second rig, at
1,056,000 compiled rows, brackets where it turns: at 12 type-level rows a single-row read
is 0.59 ms and `count(*)` 563 ms, at 1,000 rows 1.03 ms and 622 ms, at 50,000 rows 56.0 ms
and over 30 s. Somewhere between 1,000 and 50,000 the planner abandons the `BitmapOr` over
`idx_sa_auth_by_resource` and falls back to scanning `super_auth_authorizations` once per
outer row. Below about 1,000 you are in the good plan and there is nothing to do. Every
figure in this section is from a synthetic rig, not from any production install, and the
variable they are in is type-level rows on a protected type — not your record count and
not your compiled-row count. Take your own two numbers from the queries above before
deciding you have a problem: most installs sit far below the knee, where none of this is
worth doing.

Re-time any statement you believe is fine with `SET LOCAL synchronize_seqscans = off`
inside the transaction. Without it the same statement measured 20,463 ms and 8.495 ms
minutes apart, because each sequence scan starts where the last one stopped; warm numbers
taken with it on are not reproducible, and they are the likeliest reason a host believes it
has no problem.

Your only lever short of upgrading is an index, and the honest answer is that it might do
nothing. Migration 12's two expression indexes can be built on a 0.8.0 database — they are
`CONCURRENTLY`, and they index columns the 0.8.0 predicate names too — and the two
measurements of that disagree, for a reason: at ~165,000 compiled rows with a holder of a
handful of grants, 368,216 ms became 67.9 ms; at 1,056,000 rows with a holder of 8,000
per-record grants, nothing changed at all, because the planner declines an identity bitmap
it estimates at 6,415 rows when it would be re-read once per outer row. So build them
`CONCURRENTLY`, `EXPLAIN` your worst statement with `synchronize_seqscans` off, and believe
the plan rather than either number: if `Seq Scan on super_auth_authorizations` is still in
it, drop them again — on a uuid host they cost about 25 MB and roughly halve compile insert
throughput (~173k rows/s to ~79k).

Upgrading is the fix, and it is a different order of magnitude from any index, because it
changes the shape rather than the access path. 0.9.0's steps are uncorrelated with the
outer row, so the type-level step plans once per query instead of once per row: 350,173 ms
to 86 ms on the same data with no index change at all, then 86 ms to about 1 ms once
migration 12's expression indexes land. Build the indexes before you re-run `enable`, not
after: 0.9.0's policy without them is a regression against 0.8.0 on single-row reads
(512.9 ms against 70.9 ms on the uuid rig), because uncorrelated subqueries pay their full
cost to read one row where the correlated `EXISTS` stopped at the first match.

### Explaining and measuring reach

```ruby
SuperAuth.as(user) { SuperAuth::RLS.explain(:claims, claim.id) }
# => [{ step: :organization_id, user_id: 1, resource_external_type: "Organization::Member",
#       resource_external_id: 3, ... every column of the compiled row }]
Claim.super_auth_explain(claim)          # the ORM twin, for SuperAuth.current_user
# => [{ step: :type_level, ... }, { step: :id, ... }, { step: :organization_id, ... }]
```

`explain` returns the compiled rows that admit one record for the asserted identity,
each tagged with the step that admitted it, in reach order; `[]` with no identity, under
system context, for a missing record, or when nothing admits it. The ORM twin answers
`[{ step: :system }]` for the system user and reads the row `unscoped`, since the
question is usually asked about a row the user cannot see.

`SuperAuth::RLS.coverage(:claims)` is the diagnostic for moving a table's tenancy from
per-record rows to a parent column, or for checking a production dump before doing so.
It refuses nothing. Five buckets, each an Array of `{ count:, ids: [up to 20] }` entries
with only the non-zero ones present: `loss` (per holder of a type-level row on the table's
type: the rows only that grant reaches — what deleting it takes away), `null_parent` (per
parent column: rows with NULL in it, which no parent grant can reach), `orphaned_rows`
(compiled rows whose node is gone or no longer names them, by type and whether type-level),
`widening` (per holder of a parent-type row: rows the parent step admits that no per-record
row did), `deletable_nodes` (per type: the per-record nodes no user->resource edge points
at, on themselves or on any ancestor, and no child sits under — the only ones a cleanup may
delete, because access granted straight to a user has no other path). `ids` are the table's
in the first, second and fourth and `super_auth_resources` ids in the other two. Both
readers run in system context when the role may assert it and as the caller's own identity
otherwise. `coverage` needs `SELECT` on the table, `super_auth_resources` and
`super_auth_edges`, which `enable` grants to nobody; `explain` reads only the table and
`super_auth_authorizations`, so it needs neither.

### Notes

- A test database built from `db/schema.rb` has neither the policies nor the `parent_id`
  cycle trigger: Rails' default `schema_format` is `:ruby`, and `schema.rb` cannot carry a
  policy, a `FORCE ROW LEVEL SECURITY` flag, a function or a trigger. Call
  `SuperAuth::RLS.enable(...)` for each protected table and `SuperAuth::TreeGuard.install`
  from the test setup, and assert `SuperAuth::RLS.current?(...)` and
  `SuperAuth::TreeGuard.installed?` there, so a forgotten re-enable fails the suite rather
  than silently testing an unprotected database.
- Queries with no identity asserted see nothing, and writes are rejected — fail
  closed, by design. A client that has never heard of super_auth cannot accidentally
  reach protected rows.
- Creating rows needs a type-level grant on the table's type, a parent grant for the
  value the new row carries in a parent column, or system context: the policy is
  `FOR ALL` with no `WITH CHECK`, so Postgres reuses its `USING` expression for
  INSERTs and UPDATEs, and a per-record row can only match an id that already exists. A
  resource container does not replace either on a protected table, for the same reason.
- The transaction stamp calls `pg_current_xact_id()`, which assigns a real transaction
  id even to read-only transactions — one extra xid per protected transaction.
  Negligible for almost everyone; revisit with a virtual-xid variant only if
  transaction id churn ever matters at extreme read volume.
- One `external_id_type` covers the whole install, so every protected table across
  every participating app needs the same pk type, and every parent column that type.
- Postgres 13+ only (`pg_current_xact_id`). On other databases `SuperAuth::RLS`
  raises, and the ORM scope remains the enforcement layer.

## Configuration

```ruby
# config/initializers/super_auth.rb
SuperAuth.setup do |config|
  # Raise an error when a query runs without a current user set.
  # Default is :none (returns empty results silently).
  config.missing_user_behavior = :raise

  # Column type for external id columns, applied when the migrations run. Set
  # it to your application's primary key type (:bigint, :uuid, :string, ...) so
  # authorization comparisons are natively typed. Default is :string.
  config.external_id_type = :bigint
end
```

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `missing_user_behavior` | `:none`, `:raise` | `:none` | Controls what happens when `SuperAuth.current_user` is blank. `:none` returns an empty result set. `:raise` raises `SuperAuth::Error`. |
| `external_id_type` | `:string`, `:bigint`, `:uuid`, ... | `:string` | Column type for the external id columns, applied when the migrations run. Set it to your application's primary key type so every comparison against your tables' pks is natively typed — no casting anywhere. |

## Usage

SuperAuth is a rules engine engine that works on 5 different authorization concepts:

- Users
- Groups
- Roles
- Permissions
- Resources

The basis for how this works is that the rules engine is trying to match a user with a resource to determine access.
The engine determines if it can find an authorization route betewen a user and a resource. It does so by looking at users, groups, roles, permissions.

                          +---+           +---+
                          |   |           |   |      (Group, Role and Resource
                          |   v           |   v       each nest within themselves)
                         +-------+       +------+
                         | Group |<----->| Role |
                         +-------+\    / +------+
                             ^     \  /     ^
                             |      \/      |
                             |      /\      |               +---+
                             |     /  \     |               |   |
                             V    /    \    V               |   v
    +---------------+    +------+/      \+------------+    +----------+      +-------------------+
    | YourApp::User |<-->| User |<------>| Permission |<-->| Resource | <--> | YourApp::Resource |
    +---------------+    +------+        +------------+    +----------+      +-------------------+
                             ^                                  ^
                             |                                  |
                             +----------------------------------+


The lines between the boxes are called [edges](https://en.wikipedia.org/wiki/Glossary_of_graph_theory#edge).
The self-loops on `Group`, `Role` and `Resource` mean each nests within itself: a `Group`
can contain child `Group`s, a `Role` child `Role`s, and a `Resource` child `Resource`s (a
container with your records registered under it), recursively. Grants on a parent flow to
every descendant — which is why `Group`, `Role` and `Resource` are described as *trees*.

In general the super_auth has 5 different pathing strategies to search for access.

    1. users <-> group[s] <-> role[s] <-> permission <-> resource
    2. users <->              role[s] <-> permission <-> resource
    3. users <-> group[s] <->             permission <-> resource
    4. users <->                          permission <-> resource
    5. users <->                                         resource

Edges can be drawn between any 2 objects, allowing super_auth can seamlessly scale in complexity with you.
When `Group`, `Role` and `Resource` nodes are nested, the rules apply to all descendants. If there are any edges
between the specified user and the resource, then access is granted.


You can see usage examples `spec/example_spec.rb`.

We're going to need some users:

    Users:
      - Peter
      - Michael
      - Bethany
      - Eloise
      - Anna
      - Dillon
      - Guest (Unknown User)

Let's see an example company structure:

    Groups:
      - Company
        - Engineering_dept
          - Backend
          - Frontend
        - Sales Department
        - Marketing Department
      - Customers
        - CustomerA
        - CustomerB
      - Vendors
        - VendorA
        - VendorB

We're going to define a roles:

    Roles:
      - Employee
        - Engineering
          - Señor Software Developer
          - Señor Designer
          - Software Developer
          - Production Support
        - Sales and Marketing
          - Marketing Manager
          - Marketing Associate
      - CustomerRole

We're going to define some permissions:

    Permissions:
      - create
      - read
      - update
      - delete
      - invoice
      - login
      - reboot
      - deploy
      - sign_contract
      - subscribe
      - unsubscribe
      - publish_design

Finally, we need some resources:

    Resources:
      - app1
      - app2
      - staging
      - db1
      - db2
      - core_design_template
      - customer_profile
      - marketing_website
      - customer_post1
      - customer_post2
      - customer_post3

So we have sufficient prerequisite data to do some interesting authorizations. Let's draw some edges:

    Peter <-> Frontend # Peter is on the Frontend team. (via Company->Engineering_dept->Frontend)
    Engineering_dept <-> Engineering # Group "Engineering_dept" has the Role "Engineering"
    Engineering <-> create # Engineering role can do basic CRUD operations
    Engineering <-> read   # Peter can CRUD too
    Engineering <-> update
    Engineering <-> delete
    core_design_template <-> create # Now, those CRUD permissions apply to core_design_template resource
    core_design_template <-> read
    core_design_template <-> update
    core_design_template <-> delete

With this, the following paths are created from Peter to the core_design_template:

    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> create <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> read   <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> update <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> delete <-> core_design_template

    Which completes the circuit using the path
    user <-> group <-> group <-> role <-> permission <-> resource


When you create/delete an edge new authorizations are generated and stored in the `super_auth` database table.
Since the path is stored with the record, it trivial to audit access permissions using basic SQL.

TODO: Write usage instructions here

## Permission-Gated Models

Every class is authorized by its own name — nothing is derived, and a grant on one class never flows to another. That makes a subclass the natural home for privileged methods: it shares the base class's table and rows, but loading it requires its own, explicitly approved grant. If you can't load the object, you can't call its methods.

```ruby
class Resource < ApplicationRecord
  super_auth
  # Loadable by users granted the "Resource" resource type.

  class ResourceRestartPermission < Resource
    # Loadable ONLY by users granted "Resource::ResourceRestartPermission".
    def restart!
      # dangerous restart operation
    end
  end
end
```

Approve access to the subclass the same way as any other resource — register it by its class name and draw edges to it. Here the nodes sit in a container, so one edge covers every server registered under it:

```ruby
restartable = SuperAuth::Resource.create(name: "restartable servers")   # a container
servers.each do |server|
  SuperAuth::Resource.create(
    name: server.name,
    external_type: "Resource::ResourceRestartPermission",
    external_id: server.id,
    parent: restartable
  )
end
restart = SuperAuth::Permission.create(name: "restart")
SuperAuth::Edge.create(user: sa_user, permission: restart)
SuperAuth::Edge.create(permission: restart, resource: restartable)
SuperAuth::ActiveRecord::Authorization.compile!

Resource.find(id)                            # needs a "Resource" grant
Resource::ResourceRestartPermission.find(id) # needs its own explicit approval
```

Grants are per class in both directions: a `"Resource"` grant does not unlock the subclass, and a `"Resource::ResourceRestartPermission"` grant does not unlock the base class.

The resource tree is containment, not inheritance. A row compiled through a container copies the descendant node's own `external_type`, so nesting does not weaken the rule above; what weakens it is the node's position. A `"Resource::ResourceRestartPermission"` node whose parent is the `"Resource"` node is a descendant of it and receives every grant drawn on `"Resource"`. Register capability nodes as siblings of their base-class nodes, or in a container beside them as above, never as their children.

### Tenancy from a column: `parent:`

A record that belongs to something — a claim to an organization, a document to a folder — can be reached through the column that says so, instead of through a node per record. `super_auth parent:` declares the column and the types whose rows admit through it, and the scope becomes one `IN`-subquery per step, OR'd: the row's own id against the class's own name, then each parent column against its types. The tiers are capability subclasses of the parent, exactly as above:

```ruby
class Organization < ApplicationRecord
  super_auth
  # Per-organization capability nodes, registered as siblings of the
  # Organization node, never under it (containment is not inheritance):
  class Member < Organization; end        # every member holds one — the tenancy tier
  class CaseWriter < Member; end          # members who may write
  class Admin < CaseWriter; end           # organization admins; a legitimate parent type
end

class Claim < ApplicationRecord
  # Readers: anyone the organization admits at all.
  super_auth parent: { column: :organization_id,
                       resource_type: ["Organization::Member", "Organization::CaseWriter", "Organization::Admin"] }

  class Writable < Claim
    # Writers: a narrower tier, on the same column. Re-declaring on a subclass
    # replaces its parents alone; the per-record step stays keyed on "Claim::Writable".
    super_auth parent: { column: :organization_id,
                         resource_type: ["Organization::CaseWriter", "Organization::Admin"] }
  end

  class Admin < Writable
    # Platform-only: force a status, wipe review data — actions even the
    # claim's owner may not take. Granted type-level to the admin tier and
    # per record to nobody, and it declares NO parent, ever. Pairing it with
    # Organization::Admin "for symmetry" would hand every organization admin
    # these actions on their own organization's claims.
    super_auth
  end
end
```

`Claim::Admin` and `Organization::Admin` share a suffix and mean opposite things — one is the platform's, the other a per-organization node organization admins are supposed to hold — and a reader who has just learned that `Organization::Admin` is a parent type is one keystroke from the escalation. The rule the example follows: a parent type must be a capability type nobody else is granted (`Organization::Member`, never bare `Organization`, whose per-record node any grant on the organization reaches), and a subclass that exists to be *narrower* than the record's owner declares no parent.

For one parent and internal user 1 the scope is, on Postgres and SQLite (MySQL backticks):

```sql
SELECT "claims".* FROM "claims"
WHERE ("claims"."id" IN (SELECT "super_auth_authorizations"."resource_external_id" FROM "super_auth_authorizations"
                          WHERE "super_auth_authorizations"."user_id" = 1
                            AND "super_auth_authorizations"."resource_external_type" = 'Claim'
                            AND "super_auth_authorizations"."resource_external_id" IS NOT NULL)
   OR "claims"."organization_id" IN (SELECT "super_auth_authorizations"."resource_external_id" FROM "super_auth_authorizations"
                          WHERE "super_auth_authorizations"."user_id" = 1
                            AND "super_auth_authorizations"."resource_external_type" = 'Organization::Member'
                            AND "super_auth_authorizations"."resource_external_id" IS NOT NULL))
  AND "claims"."id" = 7
```

preceded by one probe for a type-level `Claim` row, which admits everything when found (`wildcard: false` on the macro drops the probe and the step). With a type list the parent step reads `IN ('Organization::Member', 'Organization::CaseWriter', 'Organization::Admin')`; an application user matches on `user_external_id` and `user_external_type`. Two statements per query, however many rows.

Rules the scope keeps: the steps are OR'd and never collapsed into the parent step, so a per-record grant admits a row whose parent column is NULL, and a user with one read edge on one claim and no organization keeps it; a subclass inherits the parents and is keyed on its own name; re-declaring on a subclass replaces its parents only, on the one inherited default scope — never a second one, which would AND with the first and deny every row the parent step admits; a type-level row on a *parent* type admits nothing (NULL equals no id); a row the user is not admitted to is absent, so `update!` and `destroy` on it affect 0 rows without an error and `reload` raises `RecordNotFound`; parents do not chain. The parent column must exist with the type of `SuperAuth.external_id_type`, checked on the first scoped query rather than at declaration, so a process boots before its migrations run, and named when wrong: "Claim declares parent column organization_id, which table claims does not have", or "Claim.organization_id is character varying(255) but super_auth_authorizations.resource_external_id is bigint; a parent column must have the type of SuperAuth.external_id_type, the type of the ids it holds". `Claim.super_auth_explain(claim)` lists the compiled rows admitting one record for the current user, each tagged `:type_level`, `:id` or the column, and `[{ step: :system }]` for the system user.

## Row-Level Security for permission-gated models

For defense in depth on Postgres (13+), enable a policy on the table with the same declaration. The policy sees only the table, not which Ruby class issued the query, so it lists every class that scopes the table under `resource_type:` and every tier's parent type under the column — it must never be narrower than any tier's ORM scope, or the ORM shows a row the database hides:

```ruby
SuperAuth::RLS.enable(:claims,
  resource_type: ["Claim", "Claim::Writable", "Claim::Admin"],
  parent: { column: :organization_id,
            resource_type: ["Organization::Member", "Organization::CaseWriter", "Organization::Admin"] })
```

`enable` turns on `ROW LEVEL SECURITY` (with `FORCE`, so the table owner is covered too) and installs the policy under the [contract described above](#the-contract-any-language), which derives visibility from `super_auth_authorizations`. Identity is asserted **per transaction, not per connection**: wrap the work in `SuperAuth.as`, which opens a transaction and calls `super_auth_become` for you. Every query inside is filtered, and the identity dies with the transaction:

```ruby
SuperAuth.as(current_user) do
  SuperAuth.db[:claims].all   # only rows current_user reaches: per record, type-level, or through organization_id
end
# outside the block there is no asserted identity, so the policy matches nothing
```

Works with `SuperAuth::User` records (matched by `user_id`) or your own user objects (matched by `user_external_id` / `user_external_type`); type-level grants (`resource_external_id IS NULL`) and the system user behave exactly as they do in the ActiveRecord scope. `SuperAuth::RLS.disable(:claims)` removes the policy.

Because the policy cannot distinguish `Claim::Writable` from `Claim`, capability enforcement — who among the admitted may write — stays with the ORM scope, in every language that writes: the database is the tenancy boundary, the client gates the capability. A `Claim::Writable` per-record row admits its row at the database for every verb, and so does an `Organization::Member` row for every claim of the organization; the create guard and the `Writable` scope are what stop a viewer from writing, as they were before there was a policy.

Notes:

- With no `SuperAuth.as` assertion in effect, the policy matches nothing (deny by default) and writes are rejected — fail closed.
- Postgres superusers and `BYPASSRLS` roles bypass row-level security entirely — run your application as a regular role (see the setup guide above).
- After a gem upgrade or a change to `parent:`, re-run `enable`: a policy already in the database does not change on its own. `SuperAuth::RLS.stale` lists the tables behind and `current?` checks one (see [Keeping the policy current](#keeping-the-policy-current)).

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/JonathanFrias/super_auth.

## License

The gem is available as open source under the terms of the [GPL v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
