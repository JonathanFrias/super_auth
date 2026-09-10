class AddSuperAuthResourceIndexes < ActiveRecord::Migration[7.0]
  # Mirrors db/migrate/12_add_resource_indexes.rb: the compiled table by the
  # resource a row names (id first — a per-record compile slices by ids
  # across several node types), the resources table by the record a node
  # points at.
  # Skipped where a host already created an index under the same name, and
  # dropped only if present, so neither direction fails against a schema the
  # host already shaped.
  def up
    unless index_name_exists?(:super_auth_authorizations, :idx_sa_auth_by_resource)
      add_index :super_auth_authorizations, [:resource_external_id, :resource_external_type], name: :idx_sa_auth_by_resource
    end
    unless index_name_exists?(:super_auth_resources, :idx_sa_resources_by_external)
      add_index :super_auth_resources, [:external_type, :external_id], name: :idx_sa_resources_by_external
    end
  end

  def down
    if index_name_exists?(:super_auth_authorizations, :idx_sa_auth_by_resource)
      remove_index :super_auth_authorizations, name: :idx_sa_auth_by_resource
    end
    if index_name_exists?(:super_auth_resources, :idx_sa_resources_by_external)
      remove_index :super_auth_resources, name: :idx_sa_resources_by_external
    end
  end
end
