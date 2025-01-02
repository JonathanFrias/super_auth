Sequel.migration do
  up do
    create_table(:super_auth_edges) do
      primary_key :id
      foreign_key :user_id,       :super_auth_users,       null: true
      foreign_key :group_id,      :super_auth_groups,      null: true
      foreign_key :permission_id, :super_auth_permissions, null: true
      foreign_key :role_id,       :super_auth_roles,       null: true
      foreign_key :resource_id,   :super_auth_resources,   null: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_edges)
  end
end
