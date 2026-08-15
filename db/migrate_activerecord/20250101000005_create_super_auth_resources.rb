class CreateSuperAuthResources < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_resources do |t|
      t.string :name
      t.column :external_id, SuperAuth.external_id_type
      t.string :external_type
      t.timestamps default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
