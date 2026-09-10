class CreateSuperAuthAuthorizations < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_authorizations do |t|
      t.integer :user_id
      t.string :user_name
      t.column :user_external_id, SuperAuth.external_id_type
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
      t.column :resource_external_id, SuperAuth.external_id_type
      t.string :resource_external_type

      # precision: nil so MySQL emits datetime, not datetime(6): MySQL 8
      # refuses a datetime(6) whose default does not name the same
      # precision ("Invalid default value for created_at"), which stopped
      # the chain at migration 1 and made the gem uninstallable there. It
      # also matches the Sequel twin, whose DateTime is datetime on MySQL;
      # on Postgres and SQLite it changes nothing.
      t.timestamps precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
