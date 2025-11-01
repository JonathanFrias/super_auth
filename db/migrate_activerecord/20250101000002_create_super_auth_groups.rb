class CreateSuperAuthGroups < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_groups do |t|
      t.string :name, null: false
      t.integer :parent_id
      t.timestamps
    end

    add_foreign_key :super_auth_groups, :super_auth_groups, column: :parent_id
  end
end
