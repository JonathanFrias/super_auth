Sequel.migration do
  up do
    create_table(:super_auth_users) do
      primary_key :id
      column :external_id, SuperAuth.sequel_external_id_type # , null: false
      String :external_type # , null: false
      String :name
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_users)
  end
end
