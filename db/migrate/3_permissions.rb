Sequel.migration do
  up do
    create_table(:super_auth_permissions) do
      primary_key :id
      String :name, null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_permissions)
  end
end
