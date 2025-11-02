# SuperAuth Graph Visualization

SuperAuth includes an interactive graph visualization tool that helps you understand and debug your authorization rules.

## Setup

### 1. Run the Installer

Generate the initializer and install migrations:

```bash
rails generate super_auth:install
```

This will:
- Create `config/initializers/super_auth.rb`
- Install SuperAuth database migrations
- Show you the next steps

### 2. Mount the Engine

Add the following to your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount SuperAuth::Engine => '/super_auth'

  # Your other routes...
end
```

## Features

### Interactive Graph

- **Nodes**: Color-coded by type (Users, Groups, Roles, Permissions, Resources)
- **Edges**: Solid lines for authorization relationships, dashed for hierarchy
- **Zoom & Pan**: Navigate large graphs easily
- **Click nodes**: View node details

### Authorization Query

1. Select a user from the dropdown
2. Select a resource from the dropdown
3. Click "Find Authorization Paths"
4. View all paths that grant access
5. See the first path highlighted on the graph

### Statistics Panel

Real-time counts of:
- Users
- Groups (with hierarchical relationships)
- Roles (with hierarchical relationships)
- Permissions
- Resources
- Authorization edges

