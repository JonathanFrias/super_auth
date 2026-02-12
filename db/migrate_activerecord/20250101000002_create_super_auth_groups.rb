class CreateSuperAuthGroups < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_groups do |t|
      t.string :name, null: false
      t.bigint :parent_id
      t.timestamps default: -> { "CURRENT_TIMESTAMP" }
    end

    add_foreign_key :super_auth_groups, :super_auth_groups, column: :parent_id
  end
end
