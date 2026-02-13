class AddByCurrentUserIndexToSuperAuthAuthorizations < ActiveRecord::Migration[8.0]
  def change
    add_index :super_auth_authorizations,
      [:user_external_id, :resource_external_type, :resource_external_id],
      name: :idx_sa_auth_by_current_user
  end
end
