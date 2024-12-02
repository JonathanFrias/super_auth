class SuperAuth::User < Sequel::Model(:super_auth_users)
  one_to_many :edges
  one_to_many :resources

  dataset_module do
    def with_edges
      join(:super_auth_edges, user_id: :id).select_all(:super_auth_users)
    end

    def with_groups
      with_edges.join(Group.from(Group.trees).as(:groups), id: :group_id).select(
        Sequel[:super_auth_users][:id].as(:id),
        Sequel[:super_auth_users][:id].as(:user_id),
        Sequel[:groups][:id].as(:group_id),
        Sequel[:super_auth_users][:name].as(:user_name),
        Sequel[:groups][:name].as(:group_name),
        Sequel[:super_auth_edges][:id].as(:edge_id),
        Sequel[:super_auth_edges][:permission_id].as(:edge_permission_id),
        Sequel[:super_auth_edges][:group_id].as(:edge_group_id),
        Sequel[:super_auth_edges][:user_id].as(:edge_user_id),
        Sequel[:super_auth_edges][:role_id].as(:edge_role_id),
        Sequel[:groups][:group_path],
        Sequel[:groups][:group_name_path],
        Sequel[:groups][:parent_id]
      )
    end

    def with_roles
      with_edges.join(Role.from(Role.trees).as(:roles), id: :role_id).select(
        Sequel[:users][:id].as(:id),
        Sequel[:users][:id].as(:user_id),
        Sequel[:roles][:id].as(:role_id),
        Sequel[:users][:name].as(:user_name),
        Sequel[:roles][:name].as(:role_name),
        Sequel[:edges][:id].as(:edge_id),
        Sequel[:edges][:permission_id].as(:edge_permission_id),
        Sequel[:edges][:group_id].as(:edge_group_id),
        Sequel[:edges][:user_id].as(:edge_user_id),
        Sequel[:edges][:role_id].as(:edge_role_id),
        Sequel[:roles][:role_path],
        Sequel[:roles][:role_name_path],
        Sequel[:roles][:parent_id]
      )
    end
  end
end
