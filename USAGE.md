# SuperAuth Usage Guide

SuperAuth is a graph-based authorization engine that makes unauthorized access structurally impossible. Instead of scattering authorization checks throughout your codebase, SuperAuth centralizes all rules in a database-backed graph and computes every valid access path automatically.

## Table of Contents

- [Installation](#installation)
- [Core Concepts](#core-concepts)
- [Quick Start](#quick-start)
- [Creating Entities](#creating-entities)
- [Drawing Edges](#drawing-edges)
- [Authorization Strategies](#authorization-strategies)
- [Querying Authorizations](#querying-authorizations)
- [Revoking Access](#revoking-access)
- [Rails Integration](#rails-integration)
- [Auditing](#auditing)
- [Visualization](#visualization)

## Installation

Add to your Gemfile:

```ruby
gem "super_auth"
```

Then run:

```bash
bundle install
```

### Rails Setup

**Step 1.** Add SuperAuth and the Sequel-ActiveRecord bridge to your Gemfile:

```ruby
gem "super_auth"
gem "sequel-activerecord_connection"
```

Then run:

```bash
bundle install
```

The `sequel-activerecord_connection` gem lets SuperAuth's Sequel engine share your existing ActiveRecord database connection, so there is nothing extra to configure.

**Step 2.** Run the install generator:

```bash
rails generate super_auth:install
```

This creates an initializer at `config/initializers/super_auth.rb`. The SuperAuth Railtie automatically connects to your ActiveRecord database and loads all models on boot -- no manual configuration is needed.

**Step 3.** Copy the SuperAuth migrations into your app and run them:

```bash
rails super_auth:install:migrations   # the engine-scoped task; railties:install:migrations also works but copies every mounted engine's migrations
rails db:migrate
```

This creates the `super_auth_*` tables (users, groups, roles, permissions, resources, edges, authorizations) alongside your application's tables. The engine does not run its migrations by itself, so repeat both commands after upgrading to a version that ships a new one (0.8.0 added migration 11, `parent_id` on resources; 0.9.0 adds 12, two indexes, and 13, the resource tree guard). A table under Postgres row-level security also needs `SuperAuth::RLS.enable` re-run after a gem upgrade, since a policy already in the database does not change on its own — see "Keeping the policy current" in the README.

**Step 4.** Set the current user in your controller:

```ruby
class ApplicationController < ActionController::Base
  before_action :set_super_auth_user

  private

  def set_super_auth_user
    SuperAuth.current_user = current_user
  end
end
```

SuperAuth uses `SuperAuth.current_user` (a thread-local) to know who is making the request. You can pass your own application's user object -- SuperAuth matches it via `external_id` and `external_type`.

**Step 5.** Add `super_auth` to any model you want to protect:

```ruby
class Post < ApplicationRecord
  super_auth
end
```

This adds a default scope that automatically filters records. Only records the current user is authorized to access will be returned from queries:

```ruby
Post.all                        # only posts the current user can access
Post.where(published: true)     # scoped AND filtered by authorization
```

A record that belongs to something can be reached through the column that says so, with no node per record: `super_auth parent: { column: :blog_id, resource_type: ["Blog::Member"] }` also admits every post whose `blog_id` the user holds a `Blog::Member` row for. See [Parent-record grants](#parent-record-grants-tenancy-from-a-column).

**Step 6 (optional).** Mount the engine, which serves the graph editor. It has no
authentication of its own, so mount it inside yours:

```ruby
# config/routes.rb
authenticate :admin do                 # Devise; or a constraints block
  mount SuperAuth::Engine => '/super_auth'
end
```

Then open `http://localhost:3000/super_auth` to edit the graph. Edits take effect at
runtime after **Recompile** (or `SuperAuth::ActiveRecord::Authorization.compile!`).

### Standalone Setup (without Rails)

```ruby
require "super_auth"

# Connect to a database
SuperAuth.db = Sequel.sqlite("super_auth.db")
# Or use an environment variable:
# ENV['SUPER_AUTH_DATABASE_URL'] = 'postgresql://user:pass@localhost/mydb'

SuperAuth.install_migrations
SuperAuth.load
```

SuperAuth uses [Sequel](https://sequel.jeremyevans.net/) for all database operations and supports SQLite, PostgreSQL, and MySQL.

## Core Concepts

SuperAuth models authorization as a graph with 5 entity types:

| Entity         | Purpose                                        | Hierarchical? |
|----------------|------------------------------------------------|---------------|
| **User**       | Who is requesting access                       | No            |
| **Group**      | Organizational units (teams, departments, etc) | Yes (nested)  |
| **Role**       | Job titles or permission sets                  | Yes (nested)  |
| **Permission** | Actions (read, write, deploy, etc)             | No            |
| **Resource**   | Things being protected (files, APIs, records)  | Yes (nested)  |

**Edges** are connections drawn between any two entities. SuperAuth traverses the graph to find all valid paths from a User to a Resource. If a path exists, access is granted.

```
                     +-------+       +------+
                     | Group |<----->| Role |
                     +-------+\    / +------+
                         ^     \  /     ^
                         |      \/      |
                         |      /\      |
                         |     /  \     |
                         V    /    \    V
+--------+          +------+/      \+------------+    +----------+
| App    |<-------->| User |<------>| Permission |<-->| Resource |
| Models |          +------+        +------------+    +----------+
+--------+              ^                                  ^
                        |                                  |
                        +----------------------------------+
```

## Quick Start

```ruby
# Create a user, a permission, and a resource
alice = SuperAuth::User.create(name: "Alice")
read  = SuperAuth::Permission.create(name: "read")
docs  = SuperAuth::Resource.create(name: "documents")

# Draw edges to connect them
SuperAuth::Edge.create(user: alice, permission: read)
SuperAuth::Edge.create(permission: read, resource: docs)

# Query authorizations
auths = SuperAuth::Edge.authorizations.all
alice_auths = auths.select { |a| a[:user_id] == alice.id }

alice_auths.first[:permission_name]  # => "read"
alice_auths.first[:resource_name]    # => "documents"
```

## Creating Entities

### Users

```ruby
# Basic user
peter = SuperAuth::User.create(name: "Peter")

# User linked to your app's user model
alice = SuperAuth::User.create(
  name: "Alice",
  external_id: 42,
  external_type: "User"
)

# System user (bypasses all authorization checks in ActiveRecord integration)
system = SuperAuth::User.system
system.system?  # => true
```

### Groups (hierarchical)

Groups represent organizational structure. They can be nested to any depth.

```ruby
company     = SuperAuth::Group.create(name: "Company")
engineering = SuperAuth::Group.create(name: "Engineering", parent: company)
backend     = SuperAuth::Group.create(name: "Backend", parent: engineering)
frontend    = SuperAuth::Group.create(name: "Frontend", parent: engineering)
```

This creates the hierarchy:

```
Company
  └── Engineering
        ├── Backend
        └── Frontend
```

Navigate the hierarchy:

```ruby
SuperAuth::Group.roots               # Groups with no parent
SuperAuth::Group.trees               # All groups with computed paths
backend.ancestors_dataset.all        # => [Engineering, Company]
company.descendants_dataset.all      # => [Engineering, Backend, Frontend]
```

A node cannot be made its own parent or moved under one of its own descendants: the save fails validation (`parent_id is inside the node's own subtree, which would close a cycle`). A cycle would make every node in it an ancestor of every other, so a grant on any of them would reach all of their subtrees, and nothing would fail loudly. `compile!` refuses a table with a cycle in it too, naming the nodes, for writes that went around the model. The same holds for roles and resources.

### Roles (hierarchical)

Roles work exactly like Groups -- they support the same nesting.

```ruby
employee     = SuperAuth::Role.create(name: "Employee")
engineer     = SuperAuth::Role.create(name: "Engineer", parent: employee)
senior_dev   = SuperAuth::Role.create(name: "Senior Developer", parent: engineer)
jr_dev       = SuperAuth::Role.create(name: "Junior Developer", parent: engineer)
```

### Permissions

Permissions are flat -- they represent actions.

```ruby
read_perm   = SuperAuth::Permission.create(name: "read")
write_perm  = SuperAuth::Permission.create(name: "write")
deploy_perm = SuperAuth::Permission.create(name: "deploy")
```

### Resources (hierarchical)

Resources represent what you are protecting. A node with neither `external_type` nor `external_id` is a container; a node with both points at one record of your application. Resources nest like groups and roles, and a grant on a node reaches the node and every node under it, so the usual shape is a container per folder, project, tenant or whatever your application nests records under, with the records registered beneath it.

```ruby
# A named resource with nothing behind it
staging = SuperAuth::Resource.create(name: "staging")

# A container, and a record of your app registered under it
reports = SuperAuth::Resource.create(name: "reports")
q3 = SuperAuth::Resource.create(
  name: "Q3 report",
  external_type: "Post",
  external_id: post.id,
  parent: reports
)

# A grant on the container reaches q3, and every node registered under
# reports later, as of the next compile!
SuperAuth::Edge.create(permission: read_perm, resource: reports)
```

Navigate the tree the same way as groups:

```ruby
SuperAuth::Resource.roots        # nodes with no parent
reports.children_dataset.all     # => [q3]
q3.parent                        # => reports
```

The compiled row for `q3` carries `q3`'s own `external_type` and `external_id` whether the edge was drawn to `q3` or to `reports`: runtime reads the record a grant reaches and nothing about how it got there. There are no resource path columns in the compiled table; "granted through which container" is a question for the graph (`parent`, `children_dataset`) and the editor.

#### Type-level grants

A node with an `external_type` and no `external_id` is a type-level grant, or wildcard: at runtime it means every record of that type, present and future. `ByCurrentUser` skips per-record filtering when one matches, and the row-level security policy's type-level step does the same in the database. It is a supported, permanent primitive — "this principal may act on every record of this type" has no cheaper spelling, and a platform admin tier is made of them. One way they go wrong: a type string that resolves to no scoped model — the class was moved to a read-only base with a `Writable` subclass and the scope went with it, or the constant is gone — compiles rows that admit nobody. In Rails, `SuperAuth::ActiveRecord::Resource.dead_type_level_nodes` lists them.

```ruby
# Every Post, present and future
posts = SuperAuth::Resource.create(name: "posts", external_type: "Post")
```

What a type-level node may not do is join the tree. `compile!` refuses, with a `SuperAuth::Error` naming the node ids, a type-level node with a parent or children: nested in the tree it would reach every record of its type through its ancestors' grants, and nodes beneath it could be reached only through a grant that already covers them. The subtree walk never descends from one either, so a granted type-level node compiles to its own `(type, NULL)` row and nothing else, on every path. A type-level node stays at the root with no children, or gets an `external_id`.

Two finders, because the nil id is easy to reach by accident: `SuperAuth::Resource.wildcards` is the type-level nodes, and `SuperAuth::Resource.record("Post", post.id)` is the node for one record, which raises `SuperAuth::Error` on a nil id rather than answering with the type-level node — a helper called with an unset foreign key would otherwise grant, revoke or label the grant that covers every Post.

Destroying a node takes its compiled rows and its edges with it, in the same transaction. Children are left where they are (the foreign key refuses to orphan them), and rows compiled *through* the node for its descendants last until the next compile, as after any other revocation.

#### Parent-record grants (tenancy from a column)

A record that belongs to something — a post to a blog, a claim to an organization — can be reached through the column that says so, with no node per record and nothing to recompile when a record is created or moves. Declare the column and the types whose rows admit through it on the model (and, on Postgres, on the policy), then grant the parent's node as usual:

```ruby
class Post < ApplicationRecord
  super_auth parent: { column: :blog_id, resource_type: ["Blog::Member"] }
end

# One node per blog, of a capability type nobody else is granted; grant it, compile
blog_node = SuperAuth::Resource.create(name: blog.title, external_type: "Blog::Member", external_id: blog.id)
SuperAuth::Edge.create(user: alice, resource: blog_node)
SuperAuth::ActiveRecord::Authorization.compile!

Post.where(blog_id: blog.id)   # alice sees every post of the blog, present and future
```

The steps are OR'd: a per-record grant on one post still admits it, with or without a `blog_id`, and a type-level `Post` grant still admits everything. A type-level `Blog::Member` row admits nothing (a column holds an id; NULL equals none), and parents do not chain. The parent type is a capability type nobody else is granted — `Blog::Member`, never bare `Blog`, whose per-record node any grant on the blog reaches — and the list under the column names every tier that may touch the row at all, because the database policy must never be narrower than any tier's ORM scope. The full contract, the Postgres side, and the platform-only subclass that must declare no parent are in the README ("Postgres Row-Level Security" and "Permission-Gated Models").

##### Moving tenancy from per-record nodes to a parent column

A table that has been carrying one node per record per member — a post node for every blog member — can drop those rows for the column. Never delete per-record nodes wholesale: a node with a direct user->resource edge (an owner, a reader granted one record) is that user's only path, and `blog_id` says nothing about them. The rule is that a per-record node may go only when no user->resource edge points at it and no child sits under it; on Postgres, `SuperAuth::RLS.coverage(:posts)` reports what the change does before it is made — `widening` (records the parent step admits that no per-record row did), `loss` (what a type-level holder would lose), `null_parent` (records no parent grant can reach), `orphaned_rows`, and `deletable_nodes`, the rule above as a sample. Over the whole table the rule is one query, and `destroy` purges each node's compiled rows and edges as it goes. Where RLS is installed the work runs as the system user, since the policy hides the rows from a process with no identity:

```ruby
deletable = SuperAuth::Resource.where(external_type: "Post").exclude(external_id: nil).
  exclude(id: SuperAuth::Edge.exclude(user_id: nil).exclude(resource_id: nil).select(:resource_id)).
  exclude(id: SuperAuth::Resource.exclude(parent_id: nil).select(:parent_id))

migrate = proc { deletable.each(&:destroy) }

if SuperAuth::RLS.installed?
  SuperAuth.as(SuperAuth::User.system, &migrate)
else
  SuperAuth.db.transaction(&migrate)
end
SuperAuth::Authorization.compile!   # SuperAuth::ActiveRecord::Authorization.compile! in Rails
```

## Drawing Edges

Edges are the core of SuperAuth. Each edge connects exactly two entities.

```ruby
# User belongs to a group
SuperAuth::Edge.create(user: peter, group: backend)

# Group has a role
SuperAuth::Edge.create(group: backend, role: engineer)

# Role has a permission
SuperAuth::Edge.create(role: engineer, permission: read_perm)

# Permission applies to a resource
SuperAuth::Edge.create(permission: read_perm, resource: staging)
```

You can also create shortcuts by skipping intermediate entities:

```ruby
# User directly linked to a role (no group)
SuperAuth::Edge.create(user: alice, role: senior_dev)

# User directly linked to a permission (no group or role)
SuperAuth::Edge.create(user: alice, permission: deploy_perm)

# Group directly linked to a permission (no role)
SuperAuth::Edge.create(group: backend, permission: write_perm)

# User directly linked to a resource (no permission check)
SuperAuth::Edge.create(user: alice, resource: staging)
```

## Authorization Strategies

SuperAuth automatically evaluates 5 pathing strategies and unions the results. You don't need to choose one -- all valid paths are discovered.

| # | Path                                                       | Use Case                            |
|---|------------------------------------------------------------|-------------------------------------|
| 1 | User -> Group(s) -> Role(s) -> Permission -> Resource      | Full organizational hierarchy       |
| 2 | User -> Role(s) -> Permission -> Resource                  | Direct role assignment              |
| 3 | User -> Group(s) -> Permission -> Resource                 | Group-level permissions (no roles)  |
| 4 | User -> Permission -> Resource                             | Direct permission grant             |
| 5 | User -> Resource                                           | Direct resource access (no permissions) |

### Hierarchy propagation

When groups or roles are nested, SuperAuth considers the full tree. If you assign a user to a parent group, they can access resources through roles attached to that group *and all its descendants*.

Resources nest too, at the other end of the path: a grant on a container reaches every node registered under it (see [Resources](#resources-hierarchical)).

```ruby
# Bethany is in Company (the root group)
SuperAuth::Edge.create(user: bethany, group: company)
SuperAuth::Edge.create(group: company, role: employee)
SuperAuth::Edge.create(role: employee, permission: login_perm)
SuperAuth::Edge.create(permission: login_perm, resource: app)

# Bethany can login to app -- the path flows through Company -> Employee -> login -> app
```

## Querying Authorizations

### Get all authorizations

```ruby
authorizations = SuperAuth::Edge.authorizations.all
```

Each row contains the full path:

```ruby
auth = authorizations.first
auth[:user_id]          # Integer
auth[:user_name]        # "Peter"
auth[:group_id]         # Integer (0 if no group in path)
auth[:group_name]       # "Backend" or nil
auth[:group_path]       # "1,2,3" (comma-separated group IDs)
auth[:group_name_path]  # "Company,Engineering,Backend"
auth[:role_id]          # Integer (0 if no role in path)
auth[:role_name]        # "Engineer" or nil
auth[:role_path]        # "1,2" (comma-separated role IDs)
auth[:role_name_path]   # "Employee,Engineer"
auth[:permission_id]    # Integer (0 if no permission in path)
auth[:permission_name]  # "read" or nil
auth[:resource_id]      # Integer
auth[:resource_name]    # "staging"
```

`resource_id` and `resource_name` are the node the grant reaches: a row compiled through a container names the descendant, not the container, and there is no resource path column (see [Resources](#resources-hierarchical)).

### Filter by user

```ruby
peter_auths = SuperAuth::Edge.authorizations.all.select { |a| a[:user_id] == peter.id }
```

### Check specific access

```ruby
auths = SuperAuth::Edge.authorizations.all

can_deploy = auths.any? { |a|
  a[:user_id] == peter.id &&
  a[:resource_name] == "staging" &&
  a[:permission_name] == "deploy"
}
```

### Query individual strategies

```ruby
SuperAuth::Edge.users_groups_roles_permissions_resources  # Strategy 1
SuperAuth::Edge.users_roles_permissions_resources         # Strategy 2
SuperAuth::Edge.users_groups_permissions_resources        # Strategy 3
SuperAuth::Edge.users_permissions_resources               # Strategy 4
SuperAuth::Edge.users_resources                           # Strategy 5
```

## Revoking Access

Delete the edge to revoke access. All authorization paths that flowed through that edge are immediately removed.

```ruby
# Find and destroy the edge
edge = SuperAuth::Edge.where(user_id: guest.id, group_id: customers.id).first
edge.destroy

# Authorizations are recomputed -- guest no longer has access through that group
```

## Rails Integration

### How it works

SuperAuth uses [Sequel](https://sequel.jeremyevans.net/) internally for its graph query engine and ships a set of ActiveRecord adapters so it integrates seamlessly with your Rails app. The `sequel-activerecord_connection` gem lets both ORMs share the same database connection, so there is nothing extra to configure.

On boot, the SuperAuth Railtie:

1. Detects your ActiveRecord database configuration
2. Creates a matching Sequel connection (shared via `sequel-activerecord_connection`)
3. Loads all SuperAuth models (both Sequel and ActiveRecord)

### ActiveRecord auto-filtering

Add `super_auth` to any model to automatically filter records based on the current user's authorizations:

```ruby
class Post < ApplicationRecord
  super_auth
end
```

Set the current user in your controller (see [Rails Setup](#rails-setup) Step 4):

```ruby
class ApplicationController < ActionController::Base
  before_action :set_super_auth_user

  private

  def set_super_auth_user
    SuperAuth.current_user = current_user
  end
end
```

Now queries are automatically scoped:

```ruby
# Only returns posts the current user is authorized to access
Post.all
Post.where(published: true)
```

The system user bypasses all filters:

```ruby
SuperAuth.current_user = SuperAuth::User.system
Post.all  # Returns all posts
```

### Permission-gated subclasses

Every class is authorized by its own name, so privileged methods belong on a subclass: it shares the base class's table and rows, but loading it requires its own explicitly approved grant — access never flows between base and subclass in either direction:

```ruby
class Post < ApplicationRecord
  super_auth

  class PostPublishPermission < Post
    def publish!
      update!(published: true)
    end
  end
end

Post.find(id)                        # needs a "Post" grant
Post::PostPublishPermission.find(id) # needs a "Post::PostPublishPermission" grant
```

Approve the subclass like any other resource — register a `SuperAuth::Resource` with `external_type: "Post::PostPublishPermission"` and draw edges to it, then recompile with `SuperAuth::ActiveRecord::Authorization.compile!`.

The resource tree is containment, not inheritance. A row compiled through a container copies the descendant node's own `external_type`, which is why the rule above survives nesting — but a `"Post::PostPublishPermission"` node registered *under* the `"Post"` node is a descendant of it and receives every grant on `"Post"`. Register capability nodes as siblings of their base-class nodes, or in a container beside them, never as their children.

A subclass inherits a `parent:` declaration and is still keyed on its own name; re-declaring on the subclass replaces its parents alone, on the one inherited scope. A subclass that exists to be *narrower* than the record's owner — actions even the owner may not take — declares no parent, ever: `Claim::Admin` keyed on `Organization::Admin` "for symmetry" would hand every organization admin those actions on their own organization's claims. The README's "Permission-Gated Models" shows `Claim::Admin` (platform-only, no parent) and `Organization::Admin` (a per-organization node, a legitimate parent type) side by side, because the names collide and the meanings are opposite.

For database-side enforcement of the same rules see "Postgres Row-Level Security" in the README (`SuperAuth::RLS.enable` takes the same `resource_type:` and `parent:`, and lists every class that scopes the table and every tier's parent type, since the policy must never be narrower than any tier's ORM scope).

### Linking to your app's models

Connect SuperAuth entities to your ActiveRecord models via `external_id` and `external_type`:

```ruby
# Link a SuperAuth user to your app's User model
sa_user = SuperAuth::User.create(
  name: user.name,
  external_id: user.id,
  external_type: "User"
)

# Link a SuperAuth resource to one Post, in a container beside its siblings
reports = SuperAuth::Resource.create(name: "reports")
sa_resource = SuperAuth::Resource.create(
  name: post.title,
  external_type: "Post",
  external_id: post.id,
  parent: reports
)
SuperAuth::Resource.record("Post", post.id)    # finds it again; raises on a nil id rather than
                                                # answering with the type-level "Post" node

# Or reach posts through the blog they belong to, with no node per post
class Post < ApplicationRecord
  super_auth parent: { column: :blog_id, resource_type: ["Blog::Member"] }
end
SuperAuth::Resource.create(name: blog.title, external_type: "Blog::Member", external_id: blog.id)
```

When `super_auth` is included in a model, the default scope matches the current user's `id` and class name against `external_id` / `external_type` in the authorizations table. This means your application user objects work directly -- no need to convert to SuperAuth users in the controller. On the resource side it matches the record's class name and `id` against `resource_external_type` / `resource_external_id`; a node with the type and no id matches every record of the type, the type-level grant described under [Resources](#resources-hierarchical); and each `parent:` column is matched against the rows of its own types, so a `Blog::Member` row for blog 3 admits every post whose `blog_id` is 3.

### ActiveRecord models

SuperAuth provides ActiveRecord-compatible models under the `SuperAuth::ActiveRecord` namespace:

```ruby
SuperAuth::ActiveRecord::User
SuperAuth::ActiveRecord::Group
SuperAuth::ActiveRecord::Role
SuperAuth::ActiveRecord::Permission
SuperAuth::ActiveRecord::Resource
SuperAuth::ActiveRecord::Edge
SuperAuth::ActiveRecord::Authorization
```

These models point to the same `super_auth_*` tables and can be used alongside the Sequel models. The ActiveRecord Edge model delegates authorization queries to the Sequel engine:

```ruby
# Works the same as SuperAuth::Edge.authorizations, but returns ActiveRecord objects
SuperAuth::ActiveRecord::Edge.authorizations
```

## Auditing

Every authorization path is stored with full context. This makes it straightforward to answer questions like:

**"Why does Peter have access to the design template?"**

```ruby
auths = SuperAuth::Edge.authorizations.all
peter_design = auths.select { |a|
  a[:user_id] == peter.id && a[:resource_name] == "core_design_template"
}

peter_design.each do |auth|
  puts "#{auth[:user_name]} -> #{auth[:group_name]} -> #{auth[:role_name]} -> #{auth[:permission_name]} -> #{auth[:resource_name]}"
end
# Peter -> Frontend -> Engineering -> create -> core_design_template
# Peter -> Frontend -> Engineering -> read   -> core_design_template
# Peter -> Frontend -> Engineering -> update -> core_design_template
# Peter -> Frontend -> Engineering -> delete -> core_design_template
```

**"Who can deploy to staging?"**

```ruby
deployers = SuperAuth::Edge.authorizations.all.select { |a|
  a[:resource_name] == "staging" && a[:permission_name] == "deploy"
}
deployers.map { |a| a[:user_name] }.uniq
```

**"Why can Alice see this post?"** — once a model declares `parent:`, the compiled table alone no longer answers this: a row is admitted by a compiled row naming a *different* record (the blog), so the answer is a join through the posts table, and `explain` is that join:

```ruby
SuperAuth.current_user = alice
Post.super_auth_explain(post)
# => [{ step: :blog_id, user_external_id: 42, user_external_type: "User",
#       resource_external_type: "Blog::Member", resource_external_id: 3, ... }]
# steps: :type_level, :id, or a parent column; [{ step: :system }] for the system user
```

On Postgres `SuperAuth::RLS.explain(:posts, post.id)` answers the same for the identity asserted on the connection, with no model loaded.

## Visualization

The graph editor shows the whole graph as five boxes (groups, roles, users,
permissions, resources), drawing groups, roles and resources as trees; click any record
to trace what it can reach and what reaches it, connect records to draw edges, create
records (including a resource container under a chosen parent), delete records and
edges, and recompile. The editor makes containers; your application registers records
under them. See the README's "Graph editor" section for the full description.

- Rails: mount the engine inside your own authentication (Step 6 above) and open
  `http://localhost:3000/super_auth`.
- Anywhere else: `super_auth-editor` serves it on loopback against
  `SUPER_AUTH_DATABASE_URL`, or `require "super_auth/editor"` and mount
  `SuperAuth::Editor` in any Rack app, inside your authentication.

Load sample data (optional, Rails):

```bash
rails runner "load File.join(SuperAuth::Engine.root, 'db/seeds/sample_data.rb')"
```

## Full Example

Here's a complete example modeling a company with departments, roles, and resources:

```ruby
# Organization
company     = SuperAuth::Group.create(name: "Acme Corp")
engineering = SuperAuth::Group.create(name: "Engineering", parent: company)
backend     = SuperAuth::Group.create(name: "Backend", parent: engineering)
frontend    = SuperAuth::Group.create(name: "Frontend", parent: engineering)
sales       = SuperAuth::Group.create(name: "Sales", parent: company)

# Roles
developer   = SuperAuth::Role.create(name: "Developer")
senior_dev  = SuperAuth::Role.create(name: "Senior Developer", parent: developer)
ops         = SuperAuth::Role.create(name: "Operations", parent: developer)

# Permissions
read   = SuperAuth::Permission.create(name: "read")
write  = SuperAuth::Permission.create(name: "write")
deploy = SuperAuth::Permission.create(name: "deploy")

# Resources
api       = SuperAuth::Resource.create(name: "api")
dashboard = SuperAuth::Resource.create(name: "dashboard")
prod_db   = SuperAuth::Resource.create(name: "production_db")

# Users
alice = SuperAuth::User.create(name: "Alice")   # Senior backend dev
bob   = SuperAuth::User.create(name: "Bob")     # Frontend dev
carol = SuperAuth::User.create(name: "Carol")   # Ops

# Assign users to groups
SuperAuth::Edge.create(user: alice, group: backend)
SuperAuth::Edge.create(user: bob, group: frontend)
SuperAuth::Edge.create(user: carol, group: backend)

# Assign roles to groups
SuperAuth::Edge.create(group: backend, role: senior_dev)
SuperAuth::Edge.create(group: frontend, role: developer)

# Give Carol ops role directly
SuperAuth::Edge.create(user: carol, role: ops)

# Assign permissions to roles
SuperAuth::Edge.create(role: developer, permission: read)
SuperAuth::Edge.create(role: developer, permission: write)
SuperAuth::Edge.create(role: ops, permission: deploy)

# Assign permissions to resources
SuperAuth::Edge.create(permission: read, resource: api)
SuperAuth::Edge.create(permission: write, resource: api)
SuperAuth::Edge.create(permission: read, resource: dashboard)
SuperAuth::Edge.create(permission: deploy, resource: api)
SuperAuth::Edge.create(permission: deploy, resource: prod_db)

# Now query:
auths = SuperAuth::Edge.authorizations.all

# Alice can read and write the API (via Backend -> Senior Developer -> read/write -> api)
# Bob can read and write the API (via Frontend -> Developer -> read/write -> api)
# Bob can read the dashboard (via Frontend -> Developer -> read -> dashboard)
# Carol can deploy to the API and prod_db (via direct ops role -> deploy)
# Carol can also read/write the API (via Backend -> Senior Developer -> read/write -> api)
```

## Configuration Reference

| Method                          | Description                                          |
|---------------------------------|------------------------------------------------------|
| `SuperAuth.load`                | Load all SuperAuth models                            |
| `SuperAuth.db`                  | Access the Sequel database connection                |
| `SuperAuth.db = connection`     | Set a custom Sequel database connection              |
| `SuperAuth.current_user = user` | Set the current user (required for AR auto-filtering)|
| `SuperAuth.current_user`        | Get the current user                                 |
| `SuperAuth.install_migrations`  | Create all `super_auth_*` tables                     |
| `SuperAuth.uninstall_migrations`| Drop all `super_auth_*` tables                       |

### Environment Variables

| Variable                   | Description                               |
|----------------------------|-------------------------------------------|
| `SUPER_AUTH_DATABASE_URL`  | Database connection string (non-Rails)    |
| `SUPER_AUTH_LOG_LEVEL`     | Set to `"debug"` for SQL query logging    |

## License

SuperAuth is available as open source under the [GPL v2 License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
