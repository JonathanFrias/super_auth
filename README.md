# SuperAuth

[![Build Status](https://github.com/JonathanFrias/super_auth/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/JonathanFrias/super_auth/actions)

Super auth is a turn-key authorization engine that makes unauthorized access unrepresentable — enforced in your database, so the same rules protect every client, in any language, that touches your data. **Stop writing authorization tests; enforce access with confidence.**

The intent is to centralize authorization for one application or many, in any language. If you look at the [OWASP top vulnerability](https://owasp.org/Top10/A01_2021-Broken_Access_Control/), broken
access control is the NUMBER 1 most common security risk in modern applications today. super_auth provides an authorization model that lets you de-risk your application, solving this issue once, confidently.


## Installation

SuperAuth enforces authorization in the database, so any language can participate. The reference client is the Ruby gem:

    gem "super_auth"


## Docs

How `super_auth` stacks up against other authentication strategies:
[Do you really understand Authorization](https://dev.to/jonathanfrias/do-you-really-understand-authorization-1o5d)

## Graph Visualization

SuperAuth includes an interactive graph visualization tool to help you understand and debug your authorization rules!

![SuperAuth Visualization](https://img.shields.io/badge/Visualization-Interactive-brightgreen)

See the complete authorization graph with:
- Color-coded nodes (Users, Groups, Roles, Permissions, Resources)
- Interactive path finding
- Real-time authorization queries
- Example scenarios from the README

**Quick Start:**

```bash
# 1. Generate initializer
rails generate super_auth:install

# 2. Mount the engine in config/routes.rb
mount SuperAuth::Engine => '/super_auth'

# 3. Load sample data (optional)
rails runner "load File.join(SuperAuth::Engine.root, 'db/seeds/sample_data.rb')"
```

Then visit: `http://localhost:3000/super_auth/visualization`

See [VISUALIZATION.md](VISUALIZATION.md) for complete documentation.

## Postgres Row-Level Security (optional)

The `ByCurrentUser` scope enforces authorization at the ORM layer. On Postgres you can
additionally enforce the same rules inside the database itself, so raw SQL, `unscoped`,
background jobs, and any other client on the same database are subject to them too —
unauthorized rows become invisible at the connection level. Enforcement is pure SQL:
participating apps don't load this gem, or Ruby, at all. The gem's role is
administrative — define the graph, compile authorizations, enable the policies — which
is what makes super_auth usable as a central authorization service for apps in any
language.

### The contract (any language)

Identity is asserted per transaction by calling the `super_auth_become` function that
`SuperAuth::RLS.enable` installs:

```sql
BEGIN;
SELECT super_auth_become(user_external_id => '42', user_external_type => 'AppUser');
-- run normal queries; rows the user isn't authorized for don't exist --
COMMIT;  -- identity dies with the transaction; there is nothing to clear
```

For a user managed inside super_auth, pass `user_id => '7'` instead; `system => true`
bypasses the policies (migrations, seeds, admin jobs).

The assertion is anchored to the calling transaction: `super_auth_become` sets
transaction-local identity settings plus a stamp of the current transaction id, and
every policy requires a stamp from the current transaction. Outside a transaction the
settings have already reverted, and identity smuggled in as session settings carries a
dead transaction's stamp — either way queries return no rows and writes are rejected.
Misuse fails closed, and the scheme works unchanged behind transaction-pooling proxies
like pgbouncer, because a transaction is exactly what they keep on one server
connection.

### Setup (Rails)

**1. Match column types to your primary keys — before your first migration.**
The policies compare `super_auth_authorizations.resource_external_id` directly
against your tables' pks with no casting, so the columns must share a type:

```ruby
# config/initializers/super_auth.rb
SuperAuth.setup do |config|
  config.external_id_type = :bigint   # Rails' default pk type; use :uuid, :string, ... to match yours
end
```

If super_auth is already migrated with the wrong type, alter the four external id
columns (`super_auth_users.external_id`, `super_auth_resources.external_id`,
`super_auth_authorizations.user_external_id`, `super_auth_authorizations.resource_external_id`)
in a migration of your own.

**2. Enable RLS on the tables you want protected:**

```bash
rails generate super_auth:rls Document Invoice
rails db:migrate
```

This creates one migration calling `SuperAuth::RLS.enable(:documents, resource_type: "Document")`
per model — you can also call that directly for tables outside Rails. `resource_type`
must match the `resource_external_type` used in your authorization rows (the model's
class name when you use the AR integration).

**3. Connect as a role RLS applies to.** Superusers and `BYPASSRLS` roles skip
policies entirely, so the app must not connect as one (owning the tables is fine —
the policies use `FORCE ROW LEVEL SECURITY`). The role needs `SELECT` on
`super_auth_authorizations`, which the policies read; `EXECUTE` on
`super_auth_become` is granted to `PUBLIC` by default, so no extra grant is needed:

```sql
CREATE ROLE app_runtime LOGIN PASSWORD '...';
GRANT SELECT, INSERT, UPDATE, DELETE ON documents, invoices TO app_runtime;
GRANT SELECT ON super_auth_authorizations TO app_runtime;
```

> ⚠️ **This is the one step that, if skipped, silently disables all protection.**
> PostgreSQL *always* lets **superusers** and roles with the **`BYPASSRLS`** attribute
> bypass row-level security. `FORCE ROW LEVEL SECURITY` only subjects the table *owner*
> to the policies — it does **not** constrain a superuser. So if your app connects to
> Postgres as a superuser (the default in many local setups and some managed hosts), the
> policies apply to nobody and every row stays visible, while everything *looks* like it
> is working. Always connect as a dedicated non-superuser, non-`BYPASSRLS` role such as
> `app_runtime` above. SuperAuth's language-specific clients check this on startup and
> warn you when the connection is able to bypass RLS.

**4. Wrap work in an identity assertion.** In Ruby:

```ruby
SuperAuth.as(current_user) do
  # every query in here is enforced by the database
end
```

`SuperAuth.as` opens a transaction and calls `super_auth_become` for you — use it in
an `around_action` (or around a job) to cover a whole request. Non-Ruby apps use the
SQL contract directly. Each policy checks `super_auth_authorizations` with the same
semantics as `ByCurrentUser`: type-level authorizations (`resource_external_id IS NULL`)
act as a wildcard, per-record authorizations match on id, `system?` users bypass.

### Notes

- Queries with no identity asserted see nothing, and writes are rejected — fail
  closed, by design. A client that has never heard of super_auth cannot accidentally
  reach protected rows.
- Creating rows requires a type-level authorization for that resource type (or system
  context): the policy is `FOR ALL` with no `WITH CHECK`, so Postgres reuses its
  `USING` expression as the implicit `WITH CHECK` for INSERTs and UPDATEs.
- The transaction stamp calls `pg_current_xact_id()`, which assigns a real transaction
  id even to read-only transactions — one extra xid per protected transaction.
  Negligible for almost everyone; revisit with a virtual-xid variant only if
  transaction id churn ever matters at extreme read volume.
- One `external_id_type` covers the whole install, so every protected table across
  every participating app needs the same pk type.
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
                          |   |           |   |      (Group nests within Group,
                          |   v           |   v       Role nests within Role)
                         +-------+       +------+
                         | Group |<----->| Role |
                         +-------+\    / +------+
                             ^     \  /     ^
                             |      \/      |
                             |      /\      |
                             |     /  \     |
                             V    /    \    V
    +---------------+    +------+/      \+------------+    +----------+      +-------------------+
    | YourApp::User |<-->| User |<------>| Permission |<-->| Resource | <--> | YourApp::Resource |
    +---------------+    +------+        +------------+    +----------+      +-------------------+
                             ^                                  ^
                             |                                  |
                             +----------------------------------+


The lines between the boxes are called [edges](https://en.wikipedia.org/wiki/Glossary_of_graph_theory#edge).
The self-loops on `Group` and `Role` mean each nests within itself: a `Group` can contain
child `Group`s and a `Role` can contain child `Role`s, recursively. Grants on a parent
flow to every descendant — which is why `Group` and `Role` are described as *trees*.

In general the super_auth has 5 different pathing strategies to search for access.

    1. users <-> group[s] <-> role[s] <-> permission <-> resource
    2. users <->              role[s] <-> permission <-> resource
    3. users <-> group[s] <->             permission <-> resource
    4. users <->                          permission <-> resource
    5. users <->                                         resource

Edges can be drawn between any 2 objects, allowing super_auth can seamlessly scale in complexity with you.
When `Group` and `Role` are used, the rules will apply to all descedants. If there are any edges
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

Approve access to the subclass the same way as any other resource — register it by its class name and draw edges to it:

```ruby
restartable = SuperAuth::Resource.create(
  name: "restartable servers",
  external_type: "Resource::ResourceRestartPermission"
)
restart = SuperAuth::Permission.create(name: "restart")
SuperAuth::Edge.create(user: sa_user, permission: restart)
SuperAuth::Edge.create(permission: restart, resource: restartable)
SuperAuth::ActiveRecord::Authorization.compile!

Resource.find(id)                            # needs a "Resource" grant
Resource::ResourceRestartPermission.find(id) # needs its own explicit approval
```

Grants are per class in both directions: a `"Resource"` grant does not unlock the subclass, and a `"Resource::ResourceRestartPermission"` grant does not unlock the base class.

## Postgres Row-Level Security

For defense in depth on Postgres (13+), SuperAuth can enforce the same rules inside the database:

```ruby
# List every class the table's rows are keyed by — nothing is inferred.
SuperAuth::RLS.enable(:resources,
  resource_type: ["Resource", "Resource::ResourceRestartPermission"])
```

`enable` turns on `ROW LEVEL SECURITY` (with `FORCE`, so the table owner is covered too) and installs a policy that derives visibility from `super_auth_authorizations` for the current user. There is nothing extra to supply at query time — the `SuperAuth.current_user` assignment your `before_action` already makes anchors the identity on the database connection, and every query after it is filtered:

```ruby
SuperAuth.current_user = user
SuperAuth.db[:resources].all   # only rows the user holds a grant on

SuperAuth.current_user = nil   # policy matches nothing again
```

Works with `SuperAuth::User` records (matched by `user_id`) or your own user objects (matched by `user_external_id` / `user_external_type`). Type-level wildcard grants (`resource_external_id IS NULL`) behave exactly like the ActiveRecord scope, and the system user bypasses the policy just like the ORM layer. A row is visible when the user holds a grant against *any* of the listed resource types — row-level security cannot tell which Ruby class issued a query, so per-class enforcement remains the ORM scope's job. `SuperAuth::RLS.disable(:resources)` removes the policy.

Notes:

- Until a current user is assigned, the policy matches nothing (deny by default).
- The identity lives on the database connection — assign `SuperAuth.current_user` at the start of each request/job (the standard `before_action` pattern), which overwrites whatever a previous checkout left behind.
- Postgres superusers always bypass row-level security — run your application as a regular role.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/JonathanFrias/super_auth.

## License

The gem is available as open source under the terms of the [GPL v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
