Sequel.migration do
  up do
    is_postgres = self.database_type == :postgres

    create_table(:super_auth_groups) do
      primary_key :id
      String :name, null: false
      # deferrable constraints only supported in PostgreSQL
      if is_postgres
        foreign_key :parent_id, :super_auth_groups, deferrable: true, type: :integer
      else
        foreign_key :parent_id, :super_auth_groups, type: :integer
      end
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:super_auth_groups)
  end
end
