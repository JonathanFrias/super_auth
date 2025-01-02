Sequel.migration do
  up do
    create_table(:super_auth_roles) do
      primary_key :id
      String :name, null: false
      foreign_key :parent_id, :super_auth_roles, deferrable: true, type: :integer
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_roles)
  end
end
