class CreateSuperAuthRoles < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_roles do |t|
      t.string :name, null: false
      t.bigint :parent_id
      # precision: nil so MySQL emits datetime, not datetime(6): MySQL 8
      # refuses a datetime(6) whose default does not name the same
      # precision ("Invalid default value for created_at"), which stopped
      # the chain at migration 1 and made the gem uninstallable there. It
      # also matches the Sequel twin, whose DateTime is datetime on MySQL;
      # on Postgres and SQLite it changes nothing.
      t.timestamps precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_foreign_key :super_auth_roles, :super_auth_roles, column: :parent_id
  end
end
