class CreateSuperAuthResources < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_resources do |t|
      t.string :name
      t.string :external_id
      t.string :external_type
      t.timestamps
    end
  end
end
