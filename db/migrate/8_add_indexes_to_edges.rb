Sequel.migration do
  # InnoDB already creates an index for every foreign key column, and will not
  # drop one a constraint depends on, so on MySQL these indexes are redundant
  # and their removal would fail. Skip them there.
  up do
    next if [:mysql, :mysql2].include?(database_type)

    add_index :super_auth_edges, :user_id
    add_index :super_auth_edges, :group_id
    add_index :super_auth_edges, :role_id
    add_index :super_auth_edges, :permission_id
    add_index :super_auth_edges, :resource_id
  end

  down do
    next if [:mysql, :mysql2].include?(database_type)

    drop_index :super_auth_edges, :user_id
    drop_index :super_auth_edges, :group_id
    drop_index :super_auth_edges, :role_id
    drop_index :super_auth_edges, :permission_id
    drop_index :super_auth_edges, :resource_id
  end
end
