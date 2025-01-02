Sequel.migration do
  up do
    create_table(:super_auth_authorizations) do
      Integer :user_id, null: true
      String :user_name, null: true
      String :user_external_id, null: true
      DateTime :user_created_at, null: true
      DateTime :user_updated_at, null: true
      Integer :group_id, null: true
      String :group_name, null: true
      String :group_path, null: true
      String :group_name_path, null: true
      String :group_parent_name, null: true
      String :group_parent_id, null: true
      DateTime :group_created_at, null: true
      DateTime :group_updated_at, null: true
      Integer :role_id, null: true
      String :role_name, null: true
      String :role_path, null: true
      String :role_name_path, null: true
      String :role_parent_id, null: true
      DateTime :role_created_at, null: true
      DateTime :role_updated_at, null: true
      Integer :permission_id, null: true
      String :permission_name, null: true
      DateTime :permission_created_at, null: true
      DateTime :permission_updated_at, null: true
      Integer :resource_id, null: true
      String :resource_name, null: true
      String :resource_external_id, null: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_authorizations)
  end
end
