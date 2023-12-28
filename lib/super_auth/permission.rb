class SuperAuth::Permission < Sequel::Model(:permissions)
  one_to_many :edges

  dataset_module do
    def with_edges
      join(:edges, permission_id: :id).select_all(:permissions)
    end

    def with_roles
      with_edges.join(Role.from(Role.trees).as(:roles), id: :role_id).select(
        Sequel[:permissions][:id].as(:id),
        Sequel[:permissions][:id].as(:permission_id),
        Sequel[:roles][:id].as(:role_id),
        Sequel[:permissions][:name].as(:permission_name),
        Sequel[:roles][:name].as(:role_name),
        Sequel[:edges][:id].as(:edge_id),
        Sequel[:edges][:permission_id].as(:edge_permission_id),
        Sequel[:edges][:group_id].as(:edge_group_id),
        Sequel[:edges][:user_id].as(:edge_user_id),
        Sequel[:edges][:role_id].as(:edge_role_id),
        :role_path,
        :role_name_path,
        :parent_id
      )
    end
  end

end
