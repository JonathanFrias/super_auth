class CreateSuperAuthUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_users do |t|
      t.string :external_id
      t.string :external_type
      t.string :name
      t.timestamps
    end
  end
end
