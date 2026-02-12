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

```bash
rails generate super_auth:install
```

This creates an initializer at `config/initializers/super_auth.rb` that calls `SuperAuth.load`.

Install the database tables:

```ruby
SuperAuth.install_migrations
```

Mount the engine for the visualization UI (optional):

```ruby
# config/routes.rb
mount SuperAuth::Engine => '/super_auth'
```

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
| **Resource**   | Things being protected (files, APIs, records)  | No            |

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

### Resources

Resources represent what you are protecting. They can link to your app's models.

```ruby
# Named resource
staging = SuperAuth::Resource.create(name: "staging")

# Linked to an ActiveRecord model
posts = SuperAuth::Resource.create(
  name: "posts",
  external_id: nil,
  external_type: "Post"
)
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

### ActiveRecord auto-filtering

Add `super_auth` to any model to automatically filter records based on the current user's authorizations:

```ruby
class Post < ApplicationRecord
  super_auth
end
```

Set the current user in your controller:

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

### Linking to your app's models

Connect SuperAuth entities to your ActiveRecord models via `external_id` and `external_type`:

```ruby
# Link a SuperAuth user to your app's User model
sa_user = SuperAuth::User.create(
  name: user.name,
  external_id: user.id,
  external_type: "User"
)

# Link a SuperAuth resource to your app's Post model
sa_resource = SuperAuth::Resource.create(
  name: "posts",
  external_type: "Post"
)
```

When `super_auth` is included in a model, it uses these external links to match authorization records.

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

## Visualization

SuperAuth includes an interactive graph visualization UI. After mounting the engine:

```ruby
# config/routes.rb
mount SuperAuth::Engine => '/super_auth'
```

Load sample data (optional):

```bash
rails runner "load File.join(SuperAuth::Engine.root, 'db/seeds/sample_data.rb')"
```

Visit `http://localhost:3000/super_auth/visualization` to see:

- Color-coded nodes for each entity type
- Interactive path finding
- Real-time authorization queries

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
api       = SuperAuth::Resource.create(name: "api", external_type: "API")
dashboard = SuperAuth::Resource.create(name: "dashboard", external_type: "Dashboard")
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

SuperAuth is available as open source under the [GPL License](https://www.gnu.org/licenses/quick-guide-gplv3.html).
