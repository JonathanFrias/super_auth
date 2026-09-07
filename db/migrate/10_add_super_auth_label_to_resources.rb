Sequel.migration do
  up do
    alter_table(:super_auth_resources) do
      add_column :super_auth_label, String
    end
  end

  down do
    alter_table(:super_auth_resources) do
      drop_column :super_auth_label
    end
  end
end
