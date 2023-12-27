class SuperAuth::User < Sequel::Model(:users)
  one_to_many :edges

  dataset_module do
    def with_edges
      join(:edges, user_id: :id).select_all(:users)
    end

    def with_groups
      with_edges.join(Group.from(Group.trees).as(:groups), id: :group_id).select(
        Sequel[:users][:id].as(:id),
        Sequel[:users][:id].as(:user_id),
        Sequel[:groups][:id].as(:group_id),
        Sequel[:users][:name].as(:user_name),
        Sequel[:groups][:name].as(:group_name),
        Sequel[:edges][:id].as(:edge_id),
        Sequel[:edges][:permission_id].as(:edge_permission_id),
        Sequel[:edges][:group_id].as(:edge_group_id),
        Sequel[:edges][:user_id].as(:edge_user_id),
        Sequel[:edges][:role_id].as(:edge_role_id),
        :group_path,
        :group_name_path,
        :parent_id
      )
    end

    def with_permissions
      with_edges.join(Permission.from(Permission.trees).as(:permissions), id: :permission_id).select(
        Sequel[:users][:id].as(:id),
        Sequel[:users][:id].as(:user_id),
        Sequel[:permissions][:id].as(:permission_id),
        Sequel[:users][:name].as(:user_name),
        Sequel[:permissions][:name].as(:permission_name),
        Sequel[:edges][:id].as(:edge_id),
        Sequel[:edges][:permission_id].as(:edge_permission_id),
        Sequel[:edges][:group_id].as(:edge_group_id),
        Sequel[:edges][:user_id].as(:edge_user_id),
        Sequel[:edges][:role_id].as(:edge_role_id),
        :permission_path,
        :permission_name_path,
        :parent_id
      )
    end
  end
end
