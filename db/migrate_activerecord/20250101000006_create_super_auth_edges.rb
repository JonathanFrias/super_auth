class CreateSuperAuthEdges < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_edges do |t|
      t.references :user, foreign_key: { to_table: :super_auth_users }, null: true
      t.references :group, foreign_key: { to_table: :super_auth_groups }, null: true
      t.references :permission, foreign_key: { to_table: :super_auth_permissions }, null: true
      t.references :role, foreign_key: { to_table: :super_auth_roles }, null: true
      t.references :resource, foreign_key: { to_table: :super_auth_resources }, null: true
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
