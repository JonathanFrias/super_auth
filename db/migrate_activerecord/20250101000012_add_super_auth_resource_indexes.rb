class AddSuperAuthResourceIndexes < ActiveRecord::Migration[7.0]
  # Mirrors db/migrate/12_add_resource_indexes.rb, which says why: the
  # compiled table by the resource a row names (id first — a per-record
  # compile slices by ids across several node types), the resources table by
  # the record a node points at, and, on Postgres only, the two expressions
  # the policy's identity halves compare (user_external_id::text and
  # user_id::text), which no plain btree can serve on a uuid or bigint host.
  # The user_id half is built on every Postgres host, because `holdings`
  # emits both identity halves for every step whatever kind of identity is
  # asserted; the user_external_id half is built only where that column's
  # catalogue type is neither varchar nor text, since varchar->text is a
  # RelabelType and migration 9's plain btree already answers the cast as a
  # seek there — a duplicate index of 47 MB and roughly +580 ms per 200,000
  # rows written at compile. The catalogue is asked rather than
  # SuperAuth.external_id_type, because the column is what the policy casts.
  # Approximate write cost of the pair, on a uuid host: a 200,000-row compile
  # insert goes from 1158 ms with two indexes to 2538 ms with four, about
  # +7 s and +25 MB per 1,000,000 rows compiled.
  #
  # CONCURRENTLY on Postgres, so this migration runs outside a transaction:
  # super_auth_authorizations is on the read path of every statement on every
  # protected table, and a plain CREATE INDEX holds ACCESS EXCLUSIVE on it for
  # the length of the build. A failed build leaves an INVALID index holding
  # the name; re-running the migration is the repair, since the check below
  # drops an invalid index of one of these names and builds it again. MySQL 8
  # builds an index online by default and SQLite is irrelevant at this scale,
  # so both keep a plain add_index.
  disable_ddl_transaction!

  def up
    postgres = connection.adapter_name.match?(/postgres/i)
    concurrent = postgres ? { algorithm: :concurrently } : {}

    unless taken?(:super_auth_authorizations, :idx_sa_auth_by_resource, postgres)
      add_index :super_auth_authorizations, [:resource_external_id, :resource_external_type],
        name: :idx_sa_auth_by_resource, **concurrent
    end
    unless taken?(:super_auth_resources, :idx_sa_resources_by_external, postgres)
      add_index :super_auth_resources, [:external_type, :external_id],
        name: :idx_sa_resources_by_external, **concurrent
    end

    return unless postgres

    unless taken?(:super_auth_authorizations, :idx_sa_auth_by_internal_user_text, postgres)
      add_index :super_auth_authorizations,
        "(user_id::text), resource_external_type, resource_external_id",
        name: :idx_sa_auth_by_internal_user_text, algorithm: :concurrently
    end

    typname = connection.select_value(<<~SQL)
      SELECT t.typname FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
      WHERE a.attrelid = to_regclass('super_auth_authorizations')
        AND a.attname = 'user_external_id' AND a.attnum > 0 AND NOT a.attisdropped
    SQL
    return if %w[varchar text].include?(typname)

    unless taken?(:super_auth_authorizations, :idx_sa_auth_by_current_user_text, postgres)
      add_index :super_auth_authorizations,
        "(user_external_id::text), user_external_type, resource_external_type, resource_external_id",
        name: :idx_sa_auth_by_current_user_text, algorithm: :concurrently
    end
  end

  # No down, for the reason in the Sequel twin: up skipped an index the host
  # already owned under the same name, and a rollback dropping by name would
  # take it with it.
  def down
  end

  private

  # True when the name is taken and this migration should leave it alone. On
  # Postgres the catalogue answers it: an index name is unique per schema, and
  # index_name_exists? reports neither an invalid index nor one on an
  # expression. An invalid index — what a failed CREATE INDEX CONCURRENTLY
  # leaves — is dropped rather than kept, since it answers no query and no
  # other index can take its name while it stands.
  def taken?(table, name, postgres)
    return connection.index_name_exists?(table, name) unless postgres

    valid = connection.select_value("SELECT i.indisvalid FROM pg_index i WHERE i.indexrelid = to_regclass(#{connection.quote(name.to_s)})")
    return false if valid.nil?
    return true if ActiveRecord::Type::Boolean.new.cast(valid)

    connection.execute("DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(name.to_s)}")
    false
  end
end
