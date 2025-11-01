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

### 3. Load Sample Data (Optional)

To see the visualization in action with sample data from the README:

```ruby
# In your Rails console or seed file:
load File.join(SuperAuth::Engine.root, 'db/seeds/sample_data.rb')
```

Or create a custom seed file:

```ruby
# db/seeds.rb
load File.join(SuperAuth::Engine.root, 'db/seeds/sample_data.rb') if Rails.env.development?
```

Then run:

```bash
bundle exec rails db:seed
```

### 3. Access the Visualization

Start your Rails server and navigate to:

```
http://localhost:3000/super_auth/visualization
```

## API Endpoints

The SuperAuth engine provides two API endpoints:

### GET /super_auth/graph

Returns the complete authorization graph as JSON:

```json
{
  "nodes": [
    {
      "id": "u1",
      "label": "Peter",
      "type": "user",
      "database_id": 1
    },
    // ... more nodes
  ],
  "edges": [
    {
      "from": "u1",
      "to": "g4",
      "type": "authorization"
    },
    // ... more edges
  ],
  "stats": {
    "users": 7,
    "groups": 12,
    "roles": 10,
    "permissions": 12,
    "resources": 11,
    "edges": 45
  }
}
```

### GET /super_auth/graph/authorize

Query authorization between a user and resource:

**Parameters:**
- `user_id` (required): The database ID of the user
- `resource_id` (required): The database ID of the resource

**Example:**

```
GET /super_auth/graph/authorize?user_id=1&resource_id=6
```

**Response:**

```json
{
  "authorized": true,
  "paths": [
    ["Peter", "Frontend", "Engineering", "create", "core_design_template"],
    ["Peter", "Frontend", "Engineering", "read", "core_design_template"]
  ],
  "count": 2
}
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

### Quick Examples

The visualization includes three pre-configured examples based on the README:

1. **Peter → core_design_template**: Shows CRUD access through Frontend group
2. **Michael → app1**: Shows deploy access through Backend group
3. **Anna → customer_post1**: Shows read access through CustomerA group

### Statistics Panel

Real-time counts of:
- Users
- Groups (with hierarchical relationships)
- Roles (with hierarchical relationships)
- Permissions
- Resources
- Authorization edges

## Using in Your Application

### Embed in Your App

You can customize the visualization by copying `visualization.html` and modifying it:

1. Copy the file to your Rails app:
   ```bash
   cp $(bundle show super_auth)/visualization.html app/views/admin/authorization_graph.html.erb
   ```

2. Update the `API_BASE` constant to match your mounted path:
   ```javascript
   const API_BASE = '/super_auth';
   ```

3. Add a route and controller action to display it:
   ```ruby
   # config/routes.rb
   get '/admin/authorization', to: 'admin#authorization'

   # app/controllers/admin_controller.rb
   def authorization
     render 'admin/authorization_graph'
   end
   ```

### Custom Styling

The visualization uses CSS variables for easy theming. Override these in your application:

```css
:root {
  --user-color: #4A90E2;
  --group-color: #7ED321;
  --role-color: #F5A623;
  --permission-color: #BD10E0;
  --resource-color: #E74C3C;
}
```

## Troubleshooting

### "Failed to load graph data"

Make sure:
1. The SuperAuth engine is properly mounted in `routes.rb`
2. Your Rails server is running
3. The database migrations have been run
4. You have at least some data to visualize

### Example buttons don't work

The example buttons look for specific users by name (Peter, Michael, Anna). If you haven't loaded the sample data or have different user names, these won't work. Create your own example functions or use the dropdowns manually.

### Graph is too crowded

For large graphs:
1. Use the zoom controls
2. Click and drag to pan
3. Click nodes to focus on specific connections
4. Use the query tool to highlight specific paths

## Performance

The visualization is optimized for graphs with:
- Up to 1000 nodes
- Up to 5000 edges

For larger graphs, consider:
- Filtering data at the API level
- Creating multiple specialized views
- Using the API endpoints directly for programmatic access

## Security

**Important**: The visualization exposes your complete authorization graph. In production:

1. Restrict access to admin users only:
   ```ruby
   # config/routes.rb
   authenticate :user, ->(user) { user.admin? } do
     mount SuperAuth::Engine => '/super_auth'
   end
   ```

2. Or use a before_action in the controller:
   ```ruby
   # app/controllers/super_auth/graph_controller.rb
   before_action :require_admin

   def require_admin
     redirect_to root_path unless current_user&.admin?
   end
   ```

3. Consider disabling in production entirely:
   ```ruby
   # config/routes.rb
   unless Rails.env.production?
     mount SuperAuth::Engine => '/super_auth'
   end
   ```
