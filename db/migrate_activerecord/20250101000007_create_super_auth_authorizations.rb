class CreateSuperAuthAuthorizations < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_authorizations do |t|
      t.integer :user_id
      t.string :user_name
      t.string :user_external_id
      t.string :user_external_type
      t.datetime :user_created_at
      t.datetime :user_updated_at

      t.integer :group_id
      t.string :group_name
      t.string :group_path
      t.string :group_name_path
      t.string :group_parent_name
      t.string :group_parent_id
      t.datetime :group_created_at
      t.datetime :group_updated_at

      t.integer :role_id
      t.string :role_name
      t.string :role_path
      t.string :role_name_path
      t.string :role_parent_id
      t.datetime :role_created_at
      t.datetime :role_updated_at

      t.integer :permission_id
      t.string :permission_name
      t.datetime :permission_created_at
      t.datetime :permission_updated_at

      t.integer :resource_id
      t.string :resource_name
      t.string :resource_external_id
      t.string :resource_external_type

      t.timestamps
    end
  end
end
