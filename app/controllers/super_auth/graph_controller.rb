module SuperAuth
  class GraphController < ActionController::Base
    protect_from_forgery with: :null_session

    before_action :initialize_super_auth

    def index
      render json: {
        nodes: nodes_data,
        edges: edges_data,
        stats: stats_data
      }
    end

    def authorize
      user_id = params[:user_id]
      resource_id = params[:resource_id]

      if user_id.blank? || resource_id.blank?
        render json: { error: 'user_id and resource_id are required' }, status: :bad_request
        return
      end

      paths = find_authorization_paths(user_id.to_i, resource_id.to_i)

      render json: {
        authorized: paths.any?,
        paths: paths,
        count: paths.length
      }
    end

    def visualization
      html_path = File.join(SuperAuth::Engine.root, 'visualization.html')
      send_file html_path, type: 'text/html', disposition: 'inline'
    end

    private

    def initialize_super_auth
      # Ensure SuperAuth is loaded
      SuperAuth.load unless defined?(SuperAuth::User) || defined?(SuperAuth::ActiveRecord::User)
    end

    def nodes_data
      nodes = []

      # Users
      user_class.all.each do |user|
        nodes << {
          id: "u#{user.id}",
          label: user.name,
          type: 'user',
          database_id: user.id
        }
      end

      # Groups with hierarchy
      group_class.all.each do |group|
        nodes << {
          id: "g#{group.id}",
          label: group.name,
          type: 'group',
          parent: group.parent_id ? "g#{group.parent_id}" : nil,
          database_id: group.id
        }
      end

      # Roles with hierarchy
      role_class.all.each do |role|
        nodes << {
          id: "r#{role.id}",
          label: role.name,
          type: 'role',
          parent: role.parent_id ? "r#{role.parent_id}" : nil,
          database_id: role.id
        }
      end

      # Permissions
      permission_class.all.each do |permission|
        nodes << {
          id: "p#{permission.id}",
          label: permission.name,
          type: 'permission',
          database_id: permission.id
        }
      end

      # Resources
      resource_class.all.each do |resource|
        nodes << {
          id: "res#{resource.id}",
          label: resource.name,
          type: 'resource',
          database_id: resource.id
        }
      end

      nodes
    end

    def edges_data
      edges = []

      edge_class.all.each do |edge|
        # Create edge connections
        if edge.user_id && edge.group_id
          edges << { from: "u#{edge.user_id}", to: "g#{edge.group_id}", type: 'authorization' }
        end

        if edge.user_id && edge.role_id
          edges << { from: "u#{edge.user_id}", to: "r#{edge.role_id}", type: 'authorization' }
        end

        if edge.user_id && edge.permission_id
          edges << { from: "u#{edge.user_id}", to: "p#{edge.permission_id}", type: 'authorization' }
        end

        if edge.user_id && edge.resource_id
          edges << { from: "u#{edge.user_id}", to: "res#{edge.resource_id}", type: 'authorization' }
        end

        if edge.group_id && edge.role_id
          edges << { from: "g#{edge.group_id}", to: "r#{edge.role_id}", type: 'authorization' }
        end

        if edge.group_id && edge.permission_id
          edges << { from: "g#{edge.group_id}", to: "p#{edge.permission_id}", type: 'authorization' }
        end

        if edge.role_id && edge.permission_id
          edges << { from: "r#{edge.role_id}", to: "p#{edge.permission_id}", type: 'authorization' }
        end

        if edge.permission_id && edge.resource_id
          edges << { from: "p#{edge.permission_id}", to: "res#{edge.resource_id}", type: 'authorization' }
        end
      end

      # Add hierarchy edges for groups
      group_class.where.not(parent_id: nil).each do |group|
        edges << { from: "g#{group.id}", to: "g#{group.parent_id}", type: 'hierarchy' }
      end

      # Add hierarchy edges for roles
      role_class.where.not(parent_id: nil).each do |role|
        edges << { from: "r#{role.id}", to: "r#{role.parent_id}", type: 'hierarchy' }
      end

      edges.uniq
    end

    def stats_data
      {
        users: user_class.count,
        groups: group_class.count,
        roles: role_class.count,
        permissions: permission_class.count,
        resources: resource_class.count,
        edges: edge_class.count
      }
    end

    def find_authorization_paths(user_id, resource_id)
      user_node = "u#{user_id}"
      resource_node = "res#{resource_id}"

      # Build adjacency list
      adjacency = build_adjacency_list

      # BFS to find all paths
      paths = []
      queue = [[user_node]]
      visited_paths = Set.new

      while queue.any? && paths.length < 100 # Limit to prevent infinite loops
        path = queue.shift
        current = path.last

        # Skip if we've seen this exact path before
        path_key = path.join(',')
        next if visited_paths.include?(path_key)
        visited_paths.add(path_key)

        # Found a complete path
        if current == resource_node
          paths << path_with_labels(path)
          next
        end

        # Prevent too-long paths
        next if path.length > 10

        # Explore neighbors
        neighbors = adjacency[current] || []
        neighbors.each do |neighbor|
          next if path.include?(neighbor) # Avoid cycles
          queue << path + [neighbor]
        end
      end

      paths
    end

    def build_adjacency_list
      adjacency = Hash.new { |h, k| h[k] = [] }

      edges_data.each do |edge|
        # Make it bidirectional for path finding
        adjacency[edge[:from]] << edge[:to]
        adjacency[edge[:to]] << edge[:from]
      end

      adjacency
    end

    def path_with_labels(path)
      path.map do |node_id|
        node = nodes_data.find { |n| n[:id] == node_id }
        node ? node[:label] : node_id
      end
    end

    # Dynamic class detection for Sequel vs ActiveRecord
    def user_class
      if defined?(SuperAuth::ActiveRecord::User)
        SuperAuth::ActiveRecord::User
      else
        SuperAuth::User
      end
    end

    def group_class
      if defined?(SuperAuth::ActiveRecord::Group)
        SuperAuth::ActiveRecord::Group
      else
        SuperAuth::Group
      end
    end

    def role_class
      if defined?(SuperAuth::ActiveRecord::Role)
        SuperAuth::ActiveRecord::Role
      else
        SuperAuth::Role
      end
    end

    def permission_class
      if defined?(SuperAuth::ActiveRecord::Permission)
        SuperAuth::ActiveRecord::Permission
      else
        SuperAuth::Permission
      end
    end

    def resource_class
      if defined?(SuperAuth::ActiveRecord::Resource)
        SuperAuth::ActiveRecord::Resource
      else
        SuperAuth::Resource
      end
    end

    def edge_class
      if defined?(SuperAuth::ActiveRecord::Edge)
        SuperAuth::ActiveRecord::Edge
      else
        SuperAuth::Edge
      end
    end
  end
end
