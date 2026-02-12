class CreateSuperAuthPermissions < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_permissions do |t|
      t.string :name, null: false
      t.timestamps default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
