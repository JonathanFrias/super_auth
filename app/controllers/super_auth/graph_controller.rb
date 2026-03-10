module SuperAuth
  class GraphController < ActionController::Base
    protect_from_forgery with: :null_session

    before_action :initialize_super_auth

    def index
      # Render the interactive graph visualization view
    end

    def data
      # Check if filters are applied
      has_filters = params[:user_id].present? || params[:resource_id].present?

      if has_filters
        # Apply filters
        edges = edge_class.all
        edges = edges.where(user_id: params[:user_id]) if params[:user_id].present?
        edges = edges.where(resource_id: params[:resource_id]) if params[:resource_id].present?

        # Get IDs of entities connected by filtered edges
        user_ids = edges.map(&:user_id).compact.uniq
        group_ids = edges.map(&:group_id).compact.uniq
        role_ids = edges.map(&:role_id).compact.uniq
        permission_ids = edges.map(&:permission_id).compact.uniq
        resource_ids = edges.map(&:resource_id).compact.uniq

        # Include parent groups and roles for hierarchy visualization
        groups = group_class.where(id: group_ids)
        groups.each do |group|
          current = group
          while current.parent_id
            parent = group_class.find_by(id: current.parent_id)
            break unless parent
            group_ids << parent.id unless group_ids.include?(parent.id)
            current = parent
          end
        end

        roles = role_class.where(id: role_ids)
        roles.each do |role|
          current = role
          while current.parent_id
            parent = role_class.find_by(id: current.parent_id)
            break unless parent
            role_ids << parent.id unless role_ids.include?(role.id)
            current = parent
          end
        end

        render json: {
          all_users: user_class.all.map { |u| { id: u.id, name: u.name } },
          all_resources: resource_class.all.map { |r| { id: r.id, name: r.name } },
          users: user_class.where(id: user_ids).map { |u| { id: u.id, name: u.name, type: 'user' } },
          groups: group_class.where(id: group_ids).map { |g| { id: g.id, name: g.name, parent_id: g.parent_id, type: 'group' } },
          roles: role_class.where(id: role_ids).map { |r| { id: r.id, name: r.name, parent_id: r.parent_id, type: 'role' } },
          permissions: permission_class.where(id: permission_ids).map { |p| { id: p.id, name: p.name, type: 'permission' } },
          resources: resource_class.where(id: resource_ids).map { |r| { id: r.id, name: r.name, type: 'resource' } },
          edges: edges.map { |e| {
            id: e.id,
            user_id: e.user_id,
            group_id: e.group_id,
            role_id: e.role_id,
            permission_id: e.permission_id,
            resource_id: e.resource_id
          }}
        }
      else
        # No filters - return all entities
        render json: {
          all_users: user_class.all.map { |u| { id: u.id, name: u.name } },
          all_resources: resource_class.all.map { |r| { id: r.id, name: r.name } },
          users: user_class.all.map { |u| { id: u.id, name: u.name, type: 'user' } },
          groups: group_class.all.map { |g| { id: g.id, name: g.name, parent_id: g.parent_id, type: 'group' } },
          roles: role_class.all.map { |r| { id: r.id, name: r.name, parent_id: r.parent_id, type: 'role' } },
          permissions: permission_class.all.map { |p| { id: p.id, name: p.name, type: 'permission' } },
          resources: resource_class.all.map { |r| { id: r.id, name: r.name, type: 'resource' } },
          edges: edge_class.all.map { |e| {
            id: e.id,
            user_id: e.user_id,
            group_id: e.group_id,
            role_id: e.role_id,
            permission_id: e.permission_id,
            resource_id: e.resource_id
          }}
        }
      end
    end

    def create_user
      user = user_class.create!(user_params)
      render json: { success: true, user: { id: user.id, name: user.name, type: 'user' } }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_user
      user_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def create_group
      group = group_class.create!(group_params)
      render json: { success: true, group: { id: group.id, name: group.name, parent_id: group.parent_id, type: 'group' } }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_group
      group_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def create_role
      role = role_class.create!(role_params)
      render json: { success: true, role: { id: role.id, name: role.name, parent_id: role.parent_id, type: 'role' } }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_role
      role_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def create_permission
      permission = permission_class.create!(permission_params)
      render json: { success: true, permission: { id: permission.id, name: permission.name, type: 'permission' } }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_permission
      permission_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def create_resource
      resource = resource_class.create!(resource_params)
      render json: { success: true, resource: { id: resource.id, name: resource.name, type: 'resource' } }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_resource
      resource_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def create_edge
      edge = edge_class.create!(edge_params)
      render json: {
        success: true,
        edge: {
          id: edge.id,
          user_id: edge.user_id,
          group_id: edge.group_id,
          role_id: edge.role_id,
          permission_id: edge.permission_id,
          resource_id: edge.resource_id
        }
      }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def delete_edge
      edge_class.find(params[:id]).destroy!
      render json: { success: true }
    rescue => e
      render json: { success: false, error: e.message }, status: 422
    end

    def compile_authorizations
      begin
        count = authorization_class.compile!

        render json: {
          success: true,
          message: "Compiled #{count} authorization paths",
          count: count
        }
      rescue => e
        render json: { success: false, error: e.message }, status: 422
      end
    end

    def orphaned
      # Find orphaned records that aren't part of any complete authorization path
      orphans = {
        users: [],
        groups: [],
        roles: [],
        permissions: [],
        resources: []
      }

      # Get all edges
      edges = edge_class.all

      # Check each user - can they reach any resource?
      user_class.find_each do |user|
        can_reach_resource = can_reach_any_resource?(user.id, edges)
        orphans[:users] << { id: user.id, name: user.name, reason: 'Cannot reach any resource' } unless can_reach_resource
      end

      # Check each resource - can any user reach it?
      resource_class.find_each do |resource|
        can_be_reached = can_resource_be_reached?(resource.id, edges)
        orphans[:resources] << { id: resource.id, name: resource.name, reason: 'Cannot be reached by any user' } unless can_be_reached
      end

      # Check groups - are they part of any user-to-resource path?
      group_class.find_each do |group|
        has_user_connection = edges.any? { |e| e.user_id && e.group_id == group.id }
        has_downstream = edges.any? { |e| e.group_id == group.id && (e.role_id || e.permission_id || e.resource_id) }

        unless has_user_connection && has_downstream
          reason = if !has_user_connection
            'Not connected to any user'
          elsif !has_downstream
            'Not connected downstream'
          end
          orphans[:groups] << { id: group.id, name: group.name, reason: reason }
        end
      end

      # Check roles
      role_class.find_each do |role|
        has_upstream = edges.any? { |e| (e.user_id || e.group_id) && e.role_id == role.id }
        has_downstream = edges.any? { |e| e.role_id == role.id && (e.permission_id || e.resource_id) }

        unless has_upstream && has_downstream
          reason = if !has_upstream
            'Not connected to any user or group'
          elsif !has_downstream
            'Not connected downstream'
          end
          orphans[:roles] << { id: role.id, name: role.name, reason: reason }
        end
      end

      # Check permissions
      permission_class.find_each do |permission|
        has_upstream = edges.any? { |e| (e.user_id || e.group_id || e.role_id) && e.permission_id == permission.id }
        has_downstream = edges.any? { |e| e.permission_id == permission.id && e.resource_id }

        unless has_upstream && has_downstream
          reason = if !has_upstream
            'Not connected to any user/group/role'
          elsif !has_downstream
            'Not connected to any resource'
          end
          orphans[:permissions] << { id: permission.id, name: permission.name, reason: reason }
        end
      end

      render json: { orphans: orphans }
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

    def authorization_class
      if defined?(SuperAuth::ActiveRecord::Authorization)
        SuperAuth::ActiveRecord::Authorization
      else
        SuperAuth::Authorization
      end
    end

    def can_reach_any_resource?(user_id, edges)
      # BFS to see if user can reach any resource through any path
      visited = Set.new
      queue = [{ type: 'user', id: user_id }]

      while queue.any?
        current = queue.shift
        key = "#{current[:type]}-#{current[:id]}"
        next if visited.include?(key)
        visited.add(key)

        return true if current[:type] == 'resource'

        case current[:type]
        when 'user'
          edges.each do |e|
            next unless e.user_id == current[:id]
            queue << { type: 'group', id: e.group_id } if e.group_id
            queue << { type: 'role', id: e.role_id } if e.role_id
            queue << { type: 'permission', id: e.permission_id } if e.permission_id
            queue << { type: 'resource', id: e.resource_id } if e.resource_id
          end
        when 'group'
          edges.each do |e|
            next unless e.group_id == current[:id]
            queue << { type: 'role', id: e.role_id } if e.role_id
            queue << { type: 'permission', id: e.permission_id } if e.permission_id
            queue << { type: 'resource', id: e.resource_id } if e.resource_id
          end
        when 'role'
          edges.each do |e|
            next unless e.role_id == current[:id]
            queue << { type: 'permission', id: e.permission_id } if e.permission_id
            queue << { type: 'resource', id: e.resource_id } if e.resource_id
          end
        when 'permission'
          edges.each do |e|
            next unless e.permission_id == current[:id]
            queue << { type: 'resource', id: e.resource_id } if e.resource_id
          end
        end
      end

      false
    end

    def can_resource_be_reached?(resource_id, edges)
      # BFS backwards to see if any user can reach this resource
      visited = Set.new
      queue = [{ type: 'resource', id: resource_id }]

      while queue.any?
        current = queue.shift
        key = "#{current[:type]}-#{current[:id]}"
        next if visited.include?(key)
        visited.add(key)

        return true if current[:type] == 'user'

        case current[:type]
        when 'resource'
          edges.each do |e|
            next unless e.resource_id == current[:id]
            queue << { type: 'user', id: e.user_id } if e.user_id
            queue << { type: 'group', id: e.group_id } if e.group_id
            queue << { type: 'role', id: e.role_id } if e.role_id
            queue << { type: 'permission', id: e.permission_id } if e.permission_id
          end
        when 'permission'
          edges.each do |e|
            next unless e.permission_id == current[:id]
            queue << { type: 'user', id: e.user_id } if e.user_id
            queue << { type: 'group', id: e.group_id } if e.group_id
            queue << { type: 'role', id: e.role_id } if e.role_id
          end
        when 'role'
          edges.each do |e|
            next unless e.role_id == current[:id]
            queue << { type: 'user', id: e.user_id } if e.user_id
            queue << { type: 'group', id: e.group_id } if e.group_id
          end
        when 'group'
          edges.each do |e|
            next unless e.group_id == current[:id]
            queue << { type: 'user', id: e.user_id } if e.user_id
          end
        end
      end

      false
    end

    def user_params
      params.require(:user).permit(:name, :external_id, :external_type)
    end

    def group_params
      params.require(:group).permit(:name, :parent_id)
    end

    def role_params
      params.require(:role).permit(:name, :parent_id)
    end

    def permission_params
      params.require(:permission).permit(:name)
    end

    def resource_params
      params.require(:resource).permit(:name, :external_id, :external_type)
    end

    def edge_params
      params.require(:edge).permit(:user_id, :group_id, :role_id, :permission_id, :resource_id)
    end
  end
end
