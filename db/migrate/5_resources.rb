Sequel.migration do
  change do
    create_table(:resources) do
      primary_key :id

      String :name
      String :external_id # , null: false

      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
