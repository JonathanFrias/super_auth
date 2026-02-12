class SuperAuth::Edge < Sequel::Model(:super_auth_edges)
  plugin :dirty

  many_to_one :user
  many_to_one :group
  many_to_one :permission
  many_to_one :role
  many_to_one :resource

  class << self
    def string_cast_type
      case SuperAuth.db.database_type
      when :mysql, :mysql2
        :char
      else
        :text
      end
    end

    def authorizations
      users_groups_roles_permissions_resources
        .union(users_roles_permissions_resources)
        .union(users_groups_permissions_resources)
        .union(users_permissions_resources)
        .union(users_resources)
    end

    def users_groups_roles_permissions_resources
      cast_type = string_cast_type
      users_groups_roles_ds = SuperAuth::User.join(:super_auth_edges, user_id: :id).
        select_all(:super_auth_users).
        join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:groups), Sequel.function(:concat, ',', Sequel[:groups][:group_path], ',').like(Sequel.function(:concat, '%,', Sequel[:groups][:id], ',%'))).
      select(
        Sequel[:super_auth_users][:id].as(:user_id),
        Sequel[:super_auth_users][:name].as(:user_name),
        Sequel[:super_auth_users][:external_id].as(:user_external_id),
        Sequel[:super_auth_users][:external_type].as(:user_external_type),
        Sequel[:super_auth_users][:created_at].as(:user_created_at),
        Sequel[:super_auth_users][:updated_at].as(:user_updated_at),
        Sequel[:groups][:id].as(:group_id),
        Sequel[:groups][:name].as(:group_name),
        Sequel[:super_auth_edges][:id].as(:edge_id),
        Sequel[:super_auth_edges][:permission_id].as(:edge_permission_id),
        Sequel[:super_auth_edges][:group_id].as(:edge_group_id),
        Sequel[:super_auth_edges][:user_id].as(:edge_user_id),
        Sequel[:super_auth_edges][:role_id].as(:edge_role_id),
        Sequel[:groups][:group_path],
        Sequel[:groups][:group_name_path],
        Sequel[:groups][:parent_id],
        Sequel[:groups][:created_at].cast(cast_type).as(:group_created_at),
        Sequel[:groups][:updated_at].cast(cast_type).as(:group_updated_at),
      ).join(Sequel[:super_auth_edges].as(:group_role_edges), Sequel[:group_role_edges][:group_id] => Sequel[:groups][:id]).select_append(
        Sequel[:group_role_edges][:id].as(:group_role_edge_id),
        Sequel[:group_role_edges][:permission_id].as(:group_role_edge_permission_id),
        Sequel[:group_role_edges][:group_id].as(:group_role_edge_group_id),
        Sequel[:group_role_edges][:user_id].as(:group_role_edge_user_id),
        Sequel[:group_role_edges][:role_id].as(:group_role_edge_role_id),
      ).join(:super_auth_roles, id: Sequel[:group_role_edges][:role_id])

      SuperAuth::Edge.from(
        SuperAuth::Edge.from(
          SuperAuth::Group.cte(SuperAuth::Group.where(id: users_groups_roles_ds.select(Sequel[:groups][:id])).select(:id)).select { [id.as(:group_id), name.as(:group_name), parent_id.as(:group_parent_id), group_path, group_name_path, created_at.cast(cast_type).as(:group_created_at), updated_at.as(:group_updated_at)] },
          SuperAuth::Role.cte(users_groups_roles_ds.select(Sequel[:group_role_edges][:role_id])).select { [id.as(:role_id), name.as(:role_name), parent_id.as(:role_parent_id), role_path, role_name_path, created_at.as(:role_created_at), updated_at.as(:role_updated_at) ] }
        ).as(:users_groups_roles_permissions_resources)
      ).join(Sequel[:super_auth_edges].as(:user_edges), Sequel[:user_edges][:group_id] => Sequel[:users_groups_roles_permissions_resources][:group_id])
       .join(Sequel[:super_auth_users], id: Sequel[:user_edges][:user_id])
       .select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel[:users_groups_roles_permissions_resources][:group_id],
          Sequel[:users_groups_roles_permissions_resources][:group_name],
          Sequel[:users_groups_roles_permissions_resources][:group_path],
          Sequel[:users_groups_roles_permissions_resources][:group_name_path],
          Sequel[:users_groups_roles_permissions_resources][:group_parent_id],
          Sequel[:users_groups_roles_permissions_resources][:group_created_at].cast(cast_type).as(:group_created_at),
          Sequel[:users_groups_roles_permissions_resources][:group_updated_at].cast(cast_type).as(:group_updated_at),

          Sequel[:users_groups_roles_permissions_resources][:role_id],
          Sequel[:users_groups_roles_permissions_resources][:role_name],
          Sequel[:users_groups_roles_permissions_resources][:role_path],
          Sequel[:users_groups_roles_permissions_resources][:role_name_path],
          Sequel[:users_groups_roles_permissions_resources][:role_parent_id],
          Sequel[:users_groups_roles_permissions_resources][:role_created_at].cast(cast_type).as(:role_created_at),
          Sequel[:users_groups_roles_permissions_resources][:role_updated_at].cast(cast_type).as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        )
       .join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:users_groups_roles_permissions_resources][:role_id])
       .join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id])
       .join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:permission_edges][:permission_id])
       .join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id])
       .distinct
    end

    def users_groups_permissions_resources
      cast_type = string_cast_type
      # Join users to their group via edges, then to the group CTE to get the user's group_path.
      # Use group_path to find all ancestor groups (any group whose id appears in the user's group_path).
      # Then join permission edges on those ancestor groups.
      SuperAuth::User.db[:super_auth_users].
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:user_groups), Sequel[:user_groups][:id] => Sequel[:user_edges][:group_id]).
        join(Sequel[:super_auth_edges].as(:group_edges),
          Sequel.function(:concat, ',', Sequel[:user_groups][:group_path], ',').like(
            Sequel.function(:concat, '%,', Sequel[:group_edges][:group_id].cast(cast_type), ',%')
          )
        ).
        join(Sequel[:super_auth_permissions], id: Sequel[:group_edges][:permission_id]).
        join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
        join(Sequel[:super_auth_resources], id: Sequel[:permission_edges][:resource_id]).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel[:user_groups][:id].as(:group_id),
          Sequel[:user_groups][:name].as(:group_name),
          Sequel[:user_groups][:group_path],
          Sequel[:user_groups][:group_name_path],
          Sequel[:user_groups][:parent_id].as(:group_parent_id),
          Sequel[:user_groups][:created_at].cast(cast_type).as(:group_created_at),
          Sequel[:user_groups][:updated_at].cast(cast_type).as(:group_updated_at),

          Sequel.lit(%[0 as "role_id"]),          # Sequel[:roles][:id].as(:role_id),
          Sequel::NULL.as(:role_name),            # Sequel[:roles][:name].as(:role_name),
          Sequel::NULL.as(:role_path),            # Sequel[:roles][:role_path],
          Sequel::NULL.as(:role_name_path),       # Sequel[:roles][:role_name_path].as(:role_name_path),
          Sequel::lit(%Q[0 as "role_parent_id"]), # Sequel[:roles][:parent_id].as(:role_parent_id),
          Sequel::NULL.as(:role_created_at),      # Sequel[:roles][:created_at].as(:role_created_at),
          Sequel::NULL.as(:role_updated_at),      # Sequel[:roles][:updated_at].as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type),
        ).
        distinct
    end

    def users_roles_permissions_resources
      cast_type = string_cast_type

      # Step 1: Find which roles users are directly linked to via edges
      user_role_ids_ds = SuperAuth::Edge.where(Sequel.~(user_id: nil) & Sequel.~(role_id: nil)).select(:role_id)

      # Step 2: Expand those roles to all descendants via CTE
      role_cte = SuperAuth::Role.cte(user_role_ids_ds).select {
        [id.as(:role_id), name.as(:role_name), parent_id.as(:role_parent_id), role_path, role_name_path, created_at.as(:role_created_at), updated_at.as(:role_updated_at)]
      }

      # Step 3: Build the query from the expanded role tree
      SuperAuth::Edge.from(role_cte.as(:users_roles_permissions_resources)).
      # Join user_edges — match users who link to any role in the expanded CTE
      # The user's edge links to an ancestor role, but the CTE path contains that ancestor
      # We use the role_path to check: the role_path of the CTE row starts with the user's linked role
      join(Sequel[:super_auth_edges].as(:user_edges),
        Sequel.function(:concat, ',', Sequel[:users_roles_permissions_resources][:role_path], ',').like(
          Sequel.function(:concat, '%,', Sequel[:user_edges][:role_id].cast(cast_type), ',%')
        )
      ).
      where(Sequel.~(Sequel[:user_edges][:user_id] => nil) & Sequel.~(Sequel[:user_edges][:role_id] => nil)).
      join(Sequel[:super_auth_users], id: Sequel[:user_edges][:user_id]).
      select(
        Sequel[:super_auth_users][:id].as(:user_id),
        Sequel[:super_auth_users][:name].as(:user_name),
        Sequel[:super_auth_users][:external_id].as(:user_external_id),
        Sequel[:super_auth_users][:external_type].as(:user_external_type),
        Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
        Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

        Sequel.lit(%Q[0 as "group_id"]),
        Sequel::NULL.as(:group_name),
        Sequel::NULL.as(:group_path),
        Sequel::NULL.as(:group_name_path),
        Sequel.lit(%Q[0 as "group_parent_id"]),
        Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_created_at"]),
        Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_updated_at"]),

        Sequel[:users_roles_permissions_resources][:role_id],
        Sequel[:users_roles_permissions_resources][:role_name],
        Sequel[:users_roles_permissions_resources][:role_path],
        Sequel[:users_roles_permissions_resources][:role_name_path],
        Sequel[:users_roles_permissions_resources][:role_parent_id],
        Sequel[:users_roles_permissions_resources][:role_created_at].cast(cast_type).as(:role_created_at),
        Sequel[:users_roles_permissions_resources][:role_updated_at].cast(cast_type).as(:role_updated_at),

        Sequel[:super_auth_permissions][:id].as(:permission_id),
        Sequel[:super_auth_permissions][:name].as(:permission_name),
        Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
        Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

        Sequel[:super_auth_resources][:id].as(:resource_id),
        Sequel[:super_auth_resources][:name].as(:resource_name),
        Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
        Sequel[:super_auth_resources][:external_type].as(:resource_external_type),
      ).
      # Join permission and resource edges on the expanded role
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:users_roles_permissions_resources][:role_id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
      join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id]).
      distinct
    end

    def users_permissions_resources
      cast_type = string_cast_type
      SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel.lit(%Q[0 as "group_id"]),      # Sequel[:groups][:group_id],
          Sequel::NULL.as(:group_name),       # Sequel[:groups][:group_name],
          Sequel::NULL.as(:group_path),       # Sequel[:groups][:group_path],
          Sequel::NULL.as(:group_name_path),  # Sequel[:groups][:group_name_path],
          Sequel.lit(%Q[0 as "group_parent_id"]),      # Sequel[:groups][:group_id],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_created_at"]), # Sequel[:groups][:group_created_at],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_updated_at"]), # Sequel[:groups][:group_updated_at],

          Sequel.lit(%Q[0 as "role_id"]),        # Sequel[:roles][:role_id],
          Sequel::NULL.as(:role_name),           # Sequel[:roles][:role_name],
          Sequel::NULL.as(:role_path),           # Sequel[:roles][:role_path],
          Sequel::NULL.as(:role_name_path),      # Sequel[:roles][:role_name_path],
          Sequel.lit(%Q[0 as "role_parent_id"]), # Sequel[:roles][:role_parent_id],
          Sequel::NULL.as(:role_created_at),     # Sequel[:roles][:role_created_at],
          Sequel::NULL.as(:role_updated_at),     # Sequel[:roles][:role_updated_at],

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        ).
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:user_id] => Sequel[:super_auth_users][:id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
      join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id]).
      distinct
    end

    def users_resources
      cast_type = string_cast_type
      SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel.lit(%Q[0 as "group_id"]),      # Sequel[:groups][:group_id],
          Sequel::NULL.as(:group_name),       # Sequel[:groups][:group_name],
          Sequel::NULL.as(:group_path),       # Sequel[:groups][:group_path],
          Sequel::NULL.as(:group_name_path),  # Sequel[:groups][:group_name_path],
          Sequel.lit(%Q[0 as "group_parent_id"]),      # Sequel[:groups][:group_id],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_created_at"]), # Sequel[:groups][:group_created_at],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_updated_at"]), # Sequel[:groups][:group_updated_at],


          Sequel.lit(%Q[0 as "role_id"]),        # Sequel[:roles][:role_id],
          Sequel::NULL.as(:role_name),           # Sequel[:roles][:role_name],
          Sequel::NULL.as(:role_path),           # Sequel[:roles][:role_path],
          Sequel::NULL.as(:role_name_path),      # Sequel[:roles][:role_name_path],
          Sequel.lit(%Q[0 as "role_parent_id"]), # Sequel[:roles][:role_parent_id],
          Sequel::NULL.as(:role_created_at),     # Sequel[:roles][:role_created_at],
          Sequel::NULL.as(:role_updated_at),     # Sequel[:roles][:role_updated_at],

          Sequel.lit(%Q[0 as "permission_id"]),
          Sequel::NULL.as(:permission_name),
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "permission_created_at"]),
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "permission_updated_at"]),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        ).
      join(Sequel[:super_auth_resources], Sequel[:user_edges][:resource_id] => Sequel[:super_auth_resources][:id]).
      distinct
    end
  end

  def to_h
    {
      user: self&.user&.name,
      group: self&.group&.name,
      role: self&.role&.name,
      resource: self&.resource&.name,
      permission: self&.permission&.name,
    }
  end
end
