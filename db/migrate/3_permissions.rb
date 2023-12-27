Sequel.migration do
  change do
    create_table(:permissions) do
      primary_key :id
      String :name, null: false

      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
