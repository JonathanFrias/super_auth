class CreateSuperAuthResources < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_resources do |t|
      t.string :name
      t.column :external_id, SuperAuth.external_id_type
      t.string :external_type
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
