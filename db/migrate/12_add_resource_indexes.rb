Sequel.migration do
  # Four lookups that ran as sequence scans. Two are the host's own work
  # around a record: the compiled table by the resource a row names, and the
  # resources table by the record a node points at, which every finder for a
  # record's node runs. The first leads on the id, not the type: a host's
  # per-record compile is keyed by record, and one record carries several
  # nodes of different types (Claim and Claim::Writable for one claim), so the
  # hot slice is "every row for these ids, whatever their type" — id-only by
  # construction, and a type-leading index can only scan and filter it.
  #
  # The other two are the policy's own, and they are Postgres only, since the
  # policy is and an expression index is not portable. Every step of the
  # policy matches the asserted identity by casting the column —
  # a.user_external_id::text and a.user_id::text, cast on the column because
  # casting the setting would turn a malformed identity into an error inside
  # every query — and a cast on a column defeats a plain btree unless it is a
  # no-op. So idx_sa_auth_by_current_user (migration 9) serves the external
  # half only where SuperAuth.external_id_type is a text type, and nothing has
  # ever indexed user_id at all. On a uuid or bigint host that is one full
  # pass over super_auth_authorizations per half per step, once per statement
  # on every protected table. These two index the expressions the policy
  # actually writes, so each half seeks instead.
  #
  # The internal half is built on every Postgres host: user_id is int4 in
  # every install (migration 7), int4->text is CoerceViaIO, and `holdings`
  # emits both identity halves for every step whatever kind of identity is
  # asserted, so an install that only ever asserts an external user pays for
  # this one too. The external half is built only where the column's
  # catalogue type is neither varchar nor text: varchar->text is a
  # RelabelType, so on the default :string install migration 9's plain btree
  # already answers the cast as a seek and this index is pure duplication —
  # 47 MB beside migration 9's 39 MB, and roughly +580 ms per 200,000 rows
  # written at compile. The catalogue is asked rather than
  # SuperAuth.external_id_type, because the column is what the policy casts
  # and a host may have altered it since; a column the query cannot find gets
  # the index, since the failure that matters is not having one.
  #
  # The write cost of the pair is approximate — a 200,000-row compile insert
  # against a 999,973-row uuid table, individual runs 920-2619 ms: two
  # indexes 1158 ms (~173k rows/s, 20 MB), four 2538 ms (~79k rows/s, 45 MB),
  # so about +7 s and +25 MB per 1,000,000 rows compiled.
  #
  # CONCURRENTLY on Postgres, which is why the whole migration runs outside a
  # transaction. A host large enough to need these cannot take an ACCESS
  # EXCLUSIVE lock on super_auth_authorizations: it sits on the read path of
  # every statement on every protected table, so a plain CREATE INDEX stalls
  # the application for the length of the build. The price is that a failed
  # build leaves an INVALID index behind, holding the name and used by no
  # planner; re-running the migration is the repair, because the check below
  # drops an index of one of these names that Postgres marks invalid and
  # builds it again. That is the one case where a name a host may own is not
  # left alone, and it costs the host nothing: an invalid index answers no
  # query, and nothing can take its name while it stands. MySQL 8 builds an
  # index online by default and SQLite is irrelevant at this scale, so both
  # keep a plain add_index.
  no_transaction

  up do
    is_postgres = database_type == :postgres
    concurrent = is_postgres ? { concurrently: true } : {}

    # True when the name is taken and the migration should leave it alone. On
    # Postgres the catalogue is the right question rather than the table's
    # index list: an index name is unique per schema, so a name taken on any
    # table blocks this one, and Sequel's `indexes` reports neither an
    # invalid index nor an index on an expression.
    taken = lambda do |table, name|
      next indexes(table).key?(name) unless is_postgres

      row = fetch("SELECT i.indisvalid FROM pg_index i WHERE i.indexrelid = to_regclass(?)", name.to_s).first
      next false unless row
      next true if row[:indisvalid]

      run "DROP INDEX CONCURRENTLY IF EXISTS #{literal(Sequel.identifier(name.to_s))}"
      false
    end

    unless taken.call(:super_auth_authorizations, :idx_sa_auth_by_resource)
      add_index :super_auth_authorizations, [:resource_external_id, :resource_external_type],
        name: :idx_sa_auth_by_resource, **concurrent
    end
    unless taken.call(:super_auth_resources, :idx_sa_resources_by_external)
      add_index :super_auth_resources, [:external_type, :external_id],
        name: :idx_sa_resources_by_external, **concurrent
    end

    next unless is_postgres

    unless taken.call(:super_auth_authorizations, :idx_sa_auth_by_internal_user_text)
      add_index :super_auth_authorizations,
        [Sequel.lit("(user_id::text)"), :resource_external_type, :resource_external_id],
        name: :idx_sa_auth_by_internal_user_text, concurrently: true
    end

    row = fetch(<<~SQL).first
      SELECT t.typname FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
      WHERE a.attrelid = to_regclass('super_auth_authorizations')
        AND a.attname = 'user_external_id' AND a.attnum > 0 AND NOT a.attisdropped
    SQL
    external_is_text = row && %w[varchar text].include?(row[:typname])

    unless external_is_text || taken.call(:super_auth_authorizations, :idx_sa_auth_by_current_user_text)
      add_index :super_auth_authorizations,
        [Sequel.lit("(user_external_id::text)"), :user_external_type, :resource_external_type, :resource_external_id],
        name: :idx_sa_auth_by_current_user_text, concurrently: true
    end
  end

  # No down: up skipped an index a host already owned under the same name,
  # and a migration cannot tell afterwards which of the two it created, so a
  # rollback that dropped by name would take a host's own index with it. An
  # index left behind costs nothing; a lost one costs a sequence scan on a
  # hot path. The tables' own drop removes them on a full uninstall.
  down do
  end
end
