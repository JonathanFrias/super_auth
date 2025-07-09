class SuperAuth::Permission < Sequel::Model(:super_auth_permissions)
  one_to_many :edges

  dataset_module do
    def with_edges
      join(:super_auth_edges, permission_id: :id).select_all(:super_auth_permissions)
    end

    def with_roles
    with_edges.join(SuperAuth::Role.from(SuperAuth::Role.trees).as(:roles), id: :role_id).select(
        Sequel[:super_auth_permissions][:id].as(:id),
        Sequel[:super_auth_permissions][:id].as(:permission_id),
        Sequel[:roles][:id].as(:role_id),
        Sequel[:super_auth_permissions][:name].as(:permission_name),
        Sequel[:roles][:name].as(:role_name),
        Sequel[:super_auth_edges][:id].as(:edge_id),
        Sequel[:super_auth_edges][:permission_id].as(:edge_permission_id),
        Sequel[:super_auth_edges][:group_id].as(:edge_group_id),
        Sequel[:super_auth_edges][:user_id].as(:edge_user_id),
        Sequel[:super_auth_edges][:role_id].as(:edge_role_id),
        :role_path,
        :role_name_path,
        :parent_id
      )
    end
  end

end
