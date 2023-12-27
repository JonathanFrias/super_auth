Sequel.migration do
  change do
    create_table(:edges) do
      primary_key :id

      foreign_key :user_id,       :users,       null: true
      foreign_key :group_id,      :groups,      null: true
      foreign_key :permission_id, :permissions, null: true
      foreign_key :role_id,       :roles,       null: true
      foreign_key :resource_id,   :resources,   null: true

      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
