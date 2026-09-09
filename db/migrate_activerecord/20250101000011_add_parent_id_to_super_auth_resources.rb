class AddParentIdToSuperAuthResources < ActiveRecord::Migration[7.0]
  # Mirrors db/migrate/11_add_parent_id_to_resources.rb. No index on MySQL:
  # InnoDB indexes the foreign key column itself.
  def change
    add_column :super_auth_resources, :parent_id, :bigint
    add_foreign_key :super_auth_resources, :super_auth_resources, column: :parent_id
    add_index :super_auth_resources, :parent_id unless connection.adapter_name.match?(/mysql|trilogy/i)
  end
end
