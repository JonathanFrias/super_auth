class CreateSuperAuthEdges < ActiveRecord::Migration[7.0]
  def change
    create_table :super_auth_edges do |t|
      t.references :user, foreign_key: { to_table: :super_auth_users }, null: true
      t.references :group, foreign_key: { to_table: :super_auth_groups }, null: true
      t.references :permission, foreign_key: { to_table: :super_auth_permissions }, null: true
      t.references :role, foreign_key: { to_table: :super_auth_roles }, null: true
      t.references :resource, foreign_key: { to_table: :super_auth_resources }, null: true
      t.timestamps
    end
  end
end
