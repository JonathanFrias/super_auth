Sequel.migration do
  up do
    add_index :super_auth_edges, :user_id
    add_index :super_auth_edges, :group_id
    add_index :super_auth_edges, :role_id
    add_index :super_auth_edges, :permission_id
    add_index :super_auth_edges, :resource_id
  end

  down do
    drop_index :super_auth_edges, :user_id
    drop_index :super_auth_edges, :group_id
    drop_index :super_auth_edges, :role_id
    drop_index :super_auth_edges, :permission_id
    drop_index :super_auth_edges, :resource_id
  end
end
