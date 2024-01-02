class SuperAuth::Edge < Sequel::Model(:super_auth_edges)
  many_to_one :user
  many_to_one :group
  many_to_one :permission
  many_to_one :role
  many_to_one :resource

  class << self

    def authorizations
      users_groups_roles_permissions_resources
        .union(users_roles_permissions_resources)
        .union(users_groups_permissions_resources)
        .union(users_permissions_resources)
    end

    def users_groups_roles_permissions_resources
      users_groups_roles_ds = SuperAuth::User.join(:super_auth_edges, user_id: :id).select_all(:super_auth_users).join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:groups), id: :group_id).select(
        Sequel[:super_auth_users][:id].as(:user_id),
        Sequel[:super_auth_users][:name].as(:user_name),
        Sequel[:super_auth_users][:external_id].as(:user_external_id),
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
        Sequel[:groups][:created_at].as(:group_created_at),
        Sequel[:groups][:updated_at].as(:group_updated_at),
      ).join(Sequel[:super_auth_edges].as(:group_role_edges), Sequel[:group_role_edges][:group_id] => Sequel[:groups][:id]).select_append(
        Sequel[:group_role_edges][:id].as(:group_role_edge_id),
        Sequel[:group_role_edges][:permission_id].as(:group_role_edge_permission_id),
        Sequel[:group_role_edges][:group_id].as(:group_role_edge_group_id),
        Sequel[:group_role_edges][:user_id].as(:group_role_edge_user_id),
        Sequel[:group_role_edges][:role_id].as(:group_role_edge_role_id),
      ).join(:super_auth_roles, id: Sequel[:group_role_edges][:role_id])

      SuperAuth::Edge.from(
        SuperAuth::Edge.from(
          SuperAuth::Group.cte(SuperAuth::Group.where(id: users_groups_roles_ds.select(Sequel[:groups][:id])).select(:id)).select { [id.as(:group_id), name.as(:group_name), parent_id.as(:group_parent_id), group_path, group_name_path, created_at.as(:group_created_at), updated_at.as(:group_updated_at)] },
          SuperAuth::Role.cte(users_groups_roles_ds.select(Sequel[:group_role_edges][:role_id])).select { [id.as(:role_id), name.as(:role_name), parent_id.as(:role_parent_id), role_path, role_name_path, created_at.as(:role_created_at), updated_at.as(:role_updated_at) ] }
        ).as(:users_groups_roles_permissions_resources)
      ).join(Sequel[:super_auth_edges].as(:user_edges), Sequel[:user_edges][:group_id] => Sequel[:users_groups_roles_permissions_resources][:group_id])
       .join(Sequel[:super_auth_users], id: Sequel[:user_edges][:user_id])
       .select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:created_at].cast(:text).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(:text).as(:user_updated_at),

          Sequel[:users_groups_roles_permissions_resources][:group_id],
          Sequel[:users_groups_roles_permissions_resources][:group_name],
          Sequel[:users_groups_roles_permissions_resources][:group_path],
          Sequel[:users_groups_roles_permissions_resources][:group_name_path],
          Sequel[:users_groups_roles_permissions_resources][:group_parent_id],
          Sequel[:users_groups_roles_permissions_resources][:group_created_at].cast(:text),
          Sequel[:users_groups_roles_permissions_resources][:group_updated_at].cast(:text),

          Sequel[:users_groups_roles_permissions_resources][:role_id],
          Sequel[:users_groups_roles_permissions_resources][:role_name],
          Sequel[:users_groups_roles_permissions_resources][:role_path],
          Sequel[:users_groups_roles_permissions_resources][:role_name_path],
          Sequel[:users_groups_roles_permissions_resources][:role_parent_id],
          Sequel[:users_groups_roles_permissions_resources][:role_created_at].cast(:text),
          Sequel[:users_groups_roles_permissions_resources][:role_updated_at].cast(:text),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(:text).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(:text).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id)
        )
       .join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:users_groups_roles_permissions_resources][:role_id])
       .join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id])
       .join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:permission_edges][:permission_id])
       .join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id])
       .distinct
    end

    def users_groups_permissions_resources
      SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:groups), id: :group_id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:created_at].cast(:text).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(:text).as(:user_updated_at),

          Sequel[:groups][:id].as(:group_id),
          Sequel[:groups][:name].as(:group_name),
          Sequel[:groups][:group_path],
          Sequel[:groups][:group_name_path],
          Sequel[:groups][:parent_id].as(:group_parent_id),
          Sequel[:groups][:created_at].cast(:text).as(:group_created_at),
          Sequel[:groups][:updated_at].cast(:text).as(:group_updated_at),

          Sequel.lit(%[0 as "role_id"]),          # Sequel[:roles][:id].as(:role_id),
          Sequel::NULL.as(:role_name),            # Sequel[:roles][:name].as(:role_name),
          Sequel::NULL.as(:role_path),            # Sequel[:roles][:role_path],
          Sequel::NULL.as(:role_name_path),       # Sequel[:roles][:role_name_path].as(:role_name_path),
          Sequel::lit(%Q[0 as "role_parent_id"]), # Sequel[:roles][:parent_id].as(:role_parent_id),
          Sequel::NULL.as(:role_created_at),      # Sequel[:roles][:created_at].as(:role_created_at),
          Sequel::NULL.as(:role_updated_at),      # Sequel[:roles][:updated_at].as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(:text).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(:text).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
        ).
        join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:group_id] => Sequel[:groups][:id]).
        join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
        join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
        join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id]).
        distinct
    end

    def users_roles_permissions_resources
      SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        join(SuperAuth::Role.from(SuperAuth::Role.trees).as(:roles), id: :role_id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:created_at].cast(:text).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(:text).as(:user_updated_at),

          Sequel.lit(%Q[0 as "group_id"]),                                       # Sequel[:super_auth_groups][:group_id],
          Sequel::NULL.as(:group_name),                                          # Sequel[:super_auth_groups][:group_name],
          Sequel::NULL.as(:group_path),                                          # Sequel[:super_auth_groups][:group_path],
          Sequel::NULL.as(:group_name_path),                                     # Sequel[:super_auth_groups][:group_name_path],
          Sequel.lit(%Q[0 as "group_parent_id"]),                                # Sequel[:super_auth_groups][:group_parent_id],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_created_at"]), # Sequel[:super_auth_groups][:group_created_at],
          Sequel.lit(%Q['1970-01-01 00:00:00.000000-00' as "group_updated_at"]), # Sequel[:super_auth_groups][:group_updated_at],

          Sequel[:roles][:id].as(:role_id),
          Sequel[:roles][:name].as(:role_name),
          Sequel[:roles][:role_path],
          Sequel[:roles][:role_name_path].as(:role_name_path),
          Sequel[:roles][:parent_id].as(:role_parent_id),
          Sequel[:roles][:created_at].cast(:text).as(:role_created_at),
          Sequel[:roles][:updated_at].cast(:text).as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(:text).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(:text).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
      ).
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:roles][:id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
      join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id]).
      distinct
    end

    def users_permissions_resources
      SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:created_at].cast(:text).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(:text).as(:user_updated_at),

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
          Sequel[:super_auth_permissions][:created_at].cast(:text).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(:text).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id)
        ).
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:user_id] => Sequel[:super_auth_users][:id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id]).
      join(Sequel[:super_auth_resources], id: Sequel[:resource_edges][:resource_id]).
      distinct
    end
  end
end