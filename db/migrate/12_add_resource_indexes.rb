Sequel.migration do
  # Two lookups that ran as sequence scans: the compiled table by the
  # resource a row names, and the resources table by the record a node points
  # at, which every finder for a record's node runs. The first leads on the
  # id, not the type: a host's per-record compile is keyed by record, and one
  # record carries several nodes of different types (Claim and Claim::Writable
  # for one claim), so the hot slice is "every row for these ids, whatever
  # their type" — id-only by construction, and a type-leading index can only
  # scan and filter it. The policy's own subqueries lead on the user match
  # and use idx_sa_auth_by_current_user, so this one is purely for host
  # per-resource work. Each index is skipped if a host created one under the same name before
  # this migration existed, and dropped on the way down only if present, so
  # neither direction fails against a schema the host already shaped. Both
  # branches read the catalogue before alter_table: inside the block self is
  # the generator.
  up do
    unless indexes(:super_auth_authorizations).key?(:idx_sa_auth_by_resource)
      add_index :super_auth_authorizations, [:resource_external_id, :resource_external_type], name: :idx_sa_auth_by_resource
    end
    unless indexes(:super_auth_resources).key?(:idx_sa_resources_by_external)
      add_index :super_auth_resources, [:external_type, :external_id], name: :idx_sa_resources_by_external
    end
  end

  # No down: up skipped an index a host already owned under the same name,
  # and a migration cannot tell afterwards which of the two it created, so a
  # rollback that dropped by name would take a host's own index with it. Two
  # indexes left behind cost nothing; a lost one costs a sequence scan on a
  # hot path. The tables' own drop removes them on a full uninstall.
  down do
  end
end
