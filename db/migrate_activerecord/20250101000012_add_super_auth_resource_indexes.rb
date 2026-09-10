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

  # No down, for the reason in the Sequel twin: up skipped an index the host
  # already owned under the same name, and a rollback dropping by name would
  # take it with it.
  def down
  end
end
