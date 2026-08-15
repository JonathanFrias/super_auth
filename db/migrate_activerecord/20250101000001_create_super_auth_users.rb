class CreateSuperAuthUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_users do |t|
      t.column :external_id, SuperAuth.external_id_type
      t.string :external_type
      t.string :name
      t.timestamps default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
