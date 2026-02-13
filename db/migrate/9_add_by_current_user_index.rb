Sequel.migration do
  up do
    add_index :super_auth_authorizations,
      [:user_external_id, :resource_external_type, :resource_external_id],
      name: :idx_sa_auth_by_current_user
  end
  down do
    drop_index :super_auth_authorizations,
      [:user_external_id, :resource_external_type, :resource_external_id],
      name: :idx_sa_auth_by_current_user
  end
end
