class CreateSuperAuthRoles < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_roles do |t|
      t.string :name, null: false
      t.integer :parent_id
      t.timestamps
    end

    add_foreign_key :super_auth_roles, :super_auth_roles, column: :parent_id
  end
end
