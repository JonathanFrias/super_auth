# Postgres Row-Level Security enforcement.
#
# ByCurrentUser filters queries at the ORM layer; RLS enforces the same
# reach inside Postgres, so raw SQL, `unscoped`, and non-Ruby clients are
# subject to it too — enforcing apps don't load this gem at all. Identity is
# asserted per transaction by two SQL functions installed by `enable`:
#
#   super_auth_become(user_external_id, user_external_type, user_id)
#     asserts a user's identity. Executable by PUBLIC.
#   super_auth_system()
#     asserts system context, which bypasses every policy. EXECUTE is
#     revoked from PUBLIC; `grant_system(role)` hands it to the roles that
#     may bypass.
#
# `enable` also grants every role SELECT on the gem's own tables, which the
# policies and the user models read, so a runtime role needs privileges on
# the application's tables and nothing else.
#
# Both set transaction-local identity settings plus a stamp of the current
# transaction id, and every policy requires a stamp from the current
# transaction. Identity therefore cannot outlive its transaction or leak
# across pooled connections — a query without a fresh assertion sees no
# rows. Both raise if the calling role is a superuser or has BYPASSRLS:
# Postgres exempts those roles from every policy, so an identity assertion
# from one would protect nothing while looking like it does.
#
# What a policy decides is reach (SuperAuth::Reach): a row is admitted when
# the asserted identity holds a compiled authorization that reaches it,
# through the row's own id — a per-record row, or a type-level row on the
# table's own type — or through a column holding the id of a record the row
# belongs to, its tenancy read off the row itself. Authorization protection
# is always the language client's ORM plus the super_auth database together:
# the policy is the tenancy boundary, and capability — which of the tenants
# admitted may write — is client code. The policy is FOR ALL with no WITH
# CHECK, so Postgres reuses USING for new and updated rows, and it gates no
# verb: a holder of a read tier passes it for UPDATE and DELETE at the
# database, and an unfiltered DELETE by such a holder removes every row of
# their tenancy without an error. That is the design, not a gap to close
# here; RLS is the portable base that lets other languages and future apps
# start from a real boundary, not the whole of authorization.
require "json"

module SuperAuth
  module RLS
    POLICY = "super_auth".freeze
    # Every name enable has ever given a policy. Postgres ORs permissive
    # policies, so one left behind under a previous name would keep admitting
    # rows beside the current one; enable drops every name here before it
    # creates POLICY, and the list only grows.
    POLICY_NAMES = %w[super_auth].freeze
    # Bumped when the policy template changes and at no other time. Recorded
    # in each policy's comment so current? and stale can tell a table built
    # by an earlier enable from one built by this one; installed? does not
    # read it and keeps meaning only that the identity functions exist.
    POLICY_VERSION = 2
    # Column types the policy compares without a cast, by Postgres internal
    # name: a reach column of the protected table against
    # super_auth_authorizations.resource_external_id must be identical or in
    # one of these families.
    TYPE_FAMILIES = [%w[int2 int4 int8], %w[text varchar]].freeze
    # The 0.8.0 policy's `resource_external_id IS NULL OR resource_external_id
    # = t.id`, as pg_get_expr deparses it (parenthesised) and as written.
    V1_SHAPE = /IS NULL\)? OR/

    class << self
      # Enable RLS on an app table with one policy mirroring ByCurrentUser.
      # resource_type: names the types whose rows reach a row by its id, and
      # parent: the columns through which other types reach it; both go
      # through SuperAuth::Reach.normalize, as the ORM macro's do, so the two
      # layers cannot drift. The USING expression is the transaction stamp
      # AND (system context OR one step per reach entry): the type-level step
      # admits every row to a holder of a (type, NULL) row, the id step and
      # each column step admit the rows whose column is among the ids the
      # holder's rows name. wildcard: false leaves the type-level step out,
      # for a table whose types are never granted type-level; a (type, NULL)
      # row then admits nothing there.
      #
      # INSERTs are gated too. The policy is FOR ALL with no WITH CHECK, so
      # Postgres reuses USING for new rows: creating a row needs a type-level
      # row for the table's type, a parent row for the value the new row
      # carries in a parent column, or system context. A NULL parent column
      # equals no id, so a parent grant never admits a row without one.
      #
      # The DDL runs in one transaction under lock_timeout: DROP and CREATE
      # POLICY take ACCESS EXCLUSIVE, and as separate statements they left a
      # window with no policy on a live table. Inside a transaction the
      # caller already holds — a migration's — it joins that one, and the
      # SET LOCAL lasts until that transaction ends. Every name in
      # POLICY_NAMES is dropped, never altered, and the fresh policy is
      # commented with its version and reach. Idempotent, and re-runnable on
      # a protected table.
      def enable(table, resource_type:, parent: nil, wildcard: true, lock_timeout: "5s", db: SuperAuth.db)
        postgres!(db)
        reach = Reach.normalize(resource_type: resource_type, parent: parent)
        unless [true, false].include?(wildcard)
          raise SuperAuth::Error, "wildcard: must be true or false, got #{wildcard.inspect}"
        end
        preflight!(table, reach, db)
        create_functions(db)
        grant_runtime_reads(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.transaction do
          db.run "SET LOCAL lock_timeout = #{db.literal(lock_timeout.to_s)}"
          db.run "ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY"
          # FORCE: apply the policy even when the app connects as the table owner
          db.run "ALTER TABLE #{t} FORCE ROW LEVEL SECURITY"
          POLICY_NAMES.each { |name| db.run "DROP POLICY IF EXISTS #{name} ON #{t}" }
          db.run "CREATE POLICY #{POLICY} ON #{t}\nUSING (\n#{using(t, reach, wildcard, db)}\n)"
          db.run "COMMENT ON POLICY #{POLICY} ON #{t} IS #{db.literal(comment(reach, wildcard))}"
        end
      end

      # Drops the table's policy under every name enable ever used; the
      # shared functions are left in place (other tables may still be
      # protected, and they are harmless on their own).
      def disable(table, lock_timeout: "5s", db: SuperAuth.db)
        postgres!(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.transaction do
          db.run "SET LOCAL lock_timeout = #{db.literal(lock_timeout.to_s)}"
          POLICY_NAMES.each { |name| db.run "DROP POLICY IF EXISTS #{name} ON #{t}" }
          db.run "ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY"
          db.run "ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY"
        end
      end

      # Whether the table carries the policy this enable would build for the
      # same arguments: row security on and forced, the policy's comment
      # equal to the one enable writes (version, reach and wildcard in one
      # canonical JSON string), and its expression free of the 0.8.0 shape,
      # whose `IS NULL OR` was evaluated once per row. For a test helper or a
      # health check after a deploy that changed parent: or upgraded the gem.
      def current?(table, resource_type:, parent: nil, wildcard: true, db: SuperAuth.db)
        postgres!(db)
        reach = Reach.normalize(resource_type: resource_type, parent: parent)
        row = policy(table, db)
        !row.nil? && row[:enabled] && row[:forced] &&
          row[:comment] == comment(reach, wildcard) && !row[:qual].to_s.match?(V1_SHAPE)
      end

      # Every table carrying a policy of the gem's whose comment is missing
      # or records a version other than POLICY_VERSION: the tables an upgrade
      # has to re-run enable on. Table names as symbols, sorted.
      def stale(db: SuperAuth.db)
        postgres!(db)
        policies(db).reject { |row| version(row[:comment]) == POLICY_VERSION }.map { |row| row[:table].to_sym }.uniq.sort
      end

      # The reach map the table's policy was built from, read back from its
      # comment, so coverage and explain work with no model loaded. Raises
      # when the table has no policy or one an earlier enable built.
      def reach(table, db: SuperAuth.db)
        postgres!(db)
        metadata(table, db)[:reach]
      end

      # Which compiled rows admit record `id` of `table` for the identity
      # currently asserted on the connection, each row a hash of its columns
      # plus :step — :type_level, :id, or the parent column — for the step
      # that admitted it. Nothing comes back with no identity asserted, under
      # system context (the system clause admits without a row), or for a
      # record that does not exist. Reads the table itself for the record's
      # parent columns, in system context when the role may assert it, so a
      # role that may not sees a record it is not admitted to as absent (see
      # `reading`).
      def explain(table, id, db: SuperAuth.db)
        postgres!(db)
        meta = metadata(table, db)
        reach = meta[:reach]
        holder = identity(db)[0, 3]
        reading(db) do
          as_holder(holder, db)
          record = db[Sequel.identifier(table.to_s)].where(id: id).select(:id, *Reach.parents(reach).keys).first
          rows = []
          if record
            rows.concat(tag(:type_level, holdings_of(type_level_where(reach[:id], db), db))) if meta[:wildcard]
            reach.each do |column, types|
              value = record[column]
              next if value.nil?
              rows.concat(tag(column, holdings_of("#{per_record_where(types, db)} AND a.resource_external_id = #{db.literal(value)}", db)))
            end
          end
          rows
        end
      end

      # What the table's compiled rows and nodes look like against its policy
      # — a diagnostic for a host moving tenancy from per-record rows to a
      # parent column, or checking a production dump before it does. Five
      # buckets, each an Array of small hashes with a :count and up to 20
      # example :ids, and only the entries whose count is above zero:
      #
      #   loss            per holder of a type-level row on one of the table's
      #                   own types: the records that holder reaches through
      #                   that row and nothing else — no per-record row, no
      #                   parent row for the value in any parent column, NULL
      #                   parents included. What deleting the type-level row
      #                   takes away. ids are the table's.
      #   null_parent     per parent column: the records whose column is NULL,
      #                   which no parent grant can reach. ids are the table's.
      #   orphaned_rows   compiled rows with nothing behind them: the node
      #                   they were compiled from is gone, or no longer names
      #                   the (type, id) the row copies — a (type, NULL) row
      #                   whose wildcard node was deleted keeps admitting every
      #                   record of the type until the next compile. Grouped by
      #                   type and whether the rows are type-level; ids are
      #                   super_auth_resources ids.
      #   widening        per holder of a parent-type row: the records that
      #                   holder reaches through a parent column and holds no
      #                   per-record row for, so the parent step admits them
      #                   for the first time. A holder a type-level row already
      #                   admits everywhere is left out. ids are the table's.
      #   deletable_nodes per own type: the per-record nodes no user->resource
      #                   edge points at. Access granted through a permission
      #                   edge travels with the permission and can be replaced
      #                   by the parent column; access granted straight to a
      #                   user — an owner, a veteran with one read grant — has
      #                   no other path and its node must stay. A node with
      #                   children is not listed until they are decided. ids
      #                   are super_auth_resources ids.
      #
      # The holder-to-row match is the SQL the policy runs, with the identity
      # settings pointed at each holder in turn, so what coverage counts as
      # reached is exactly what the policy admits. A type-level row on a
      # parent type is never counted as reaching anything: a column holds an
      # id, and NULL equals none. Reads run in system context when the role
      # may assert it, and otherwise as the identity the caller has, which
      # sees only its own rows (see `reading`); either way the role needs
      # SELECT on the table and on super_auth_resources and super_auth_edges,
      # which enable grants to nobody.
      def coverage(table, db: SuperAuth.db)
        postgres!(db)
        meta = metadata(table, db)
        reach = meta[:reach]
        parents = Reach.parents(reach)
        t = Sequel.identifier(table.to_s)
        tq = db.literal(t)
        reading(db) do
          {
            loss: loss(t, tq, reach, db),
            null_parent: parents.keys.filter_map { |column|
              entry = sample(t, "#{tq}.#{db.literal(Sequel.identifier(column.to_s))} IS NULL", db)
              { column: column, **entry } if entry[:count] > 0
            },
            orphaned_rows: orphaned_rows(reach, db),
            widening: widening(t, tq, reach, meta[:wildcard], db),
            deletable_nodes: deletable_nodes(reach, db),
          }
        end
      end

      # Run the block with `user`'s identity asserted for one transaction —
      # the Ruby face of the SQL contract
      # (BEGIN; SELECT super_auth_become(...); queries; COMMIT). Sequel and
      # ActiveRecord queries inside the block share the transaction's
      # connection, so the policies see the identity; it dies with the
      # transaction. A user whose `system?` is true asserts system context
      # through super_auth_system() instead, which the connection's role
      # must have been granted EXECUTE on.
      #
      # Inside an enclosing transaction (the caller's, or an outer `as`) it
      # joins that transaction instead of opening one, and it puts the
      # enclosing identity back when the block ends, however it ends: the
      # innermost assertion wins inside the block and nothing else afterwards.
      # This touches only the database settings; SuperAuth.as is the call that
      # also sets SuperAuth.current_user.
      #
      # Transaction options pass through to Sequel's transaction. One matters
      # for a wrapper that exists only to carry an identity:
      #   auto_savepoint: true   every nested transaction becomes a savepoint
      #                          (the ActiveRecord bridge turns this into
      #                          joinable: false), so a save inside the block
      #                          commits on its own and its after_commit hooks
      #                          fire then, not at the end of the block.
      # Whether a write survives the block raising is the caller's policy, not
      # this wrapper's: rescue inside the block to keep it, or let the
      # exception out to roll it back.
      def as(user, db: SuperAuth.db, **transaction_options)
        postgres!(db)
        # Outside a transaction the settings die at COMMIT and there is nothing
        # to restore; inside one, the enclosing identity must survive the block.
        enclosing = db.in_transaction? ? identity(db) : nil
        db.transaction(**transaction_options) do
          assert(user, db: db)
          begin
            yield
          ensure
            restore(enclosing, db) if enclosing
          end
        end
      end

      # Assert `user`'s identity in the transaction the caller already holds,
      # without opening one: the SELECT super_auth_become(...) half of the
      # contract, or super_auth_system() for a user whose `system?` is true.
      # For re-asserting mid-transaction, and for code that manages its own
      # transaction and only needs the identity in it. Outside a transaction
      # the settings die with the statement, so it protects nothing there.
      def assert(user, db: SuperAuth.db)
        postgres!(db)
        if user.respond_to?(:system?) && user.system?
          db.get(Sequel.function(:super_auth_system))
        else
          db.get(Sequel.function(:super_auth_become, *become_args(user)))
        end
      end

      # Whether `enable` has run on this database: both identity functions
      # exist with their current signatures. One query per call, so a hot
      # path memoises it. False on a non-Postgres database, where RLS cannot
      # be installed.
      def installed?(db: SuperAuth.db)
        return false unless db.database_type == :postgres
        db.get(Sequel.lit("to_regprocedure('super_auth_become(text,text,text)') IS NOT NULL AND to_regprocedure('super_auth_system()') IS NOT NULL"))
      end

      # Allow `role` to assert system context: SuperAuth.as with a user whose
      # system? is true, or SELECT super_auth_system() directly. enable revokes
      # this from PUBLIC; grant it to the roles that run migrations, seeds and
      # admin jobs, and to nothing else.
      def grant_system(role, db: SuperAuth.db)
        postgres!(db)
        db.run "GRANT EXECUTE ON FUNCTION super_auth_system() TO #{db.literal(Sequel.identifier(role.to_s))}"
      end

      private

      # ---- The policy text. Each clause is one method, and the same methods
      # build the coverage and explain queries, so the shapes cannot drift.

      # Identity from this transaction only.
      STAMP = "current_setting('super_auth.xid', true) = pg_current_xact_id()::text".freeze
      SYSTEM = "COALESCE(current_setting('super_auth.system', true), '') = 'true'".freeze
      # The two halves of "this compiled row belongs to the asserted
      # identity", with `a` the super_auth_authorizations alias. The column is
      # cast to text rather than the setting to the column's type: a setting
      # is free text, and casting it would turn a malformed identity into an
      # error inside every query instead of into no rows.
      INTERNAL_USER = "a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')".freeze
      EXTERNAL_USER = "a.user_external_id::text = NULLIF(current_setting('super_auth.user_external_id', true), '') " \
        "AND a.user_external_type = NULLIF(current_setting('super_auth.user_external_type', true), '')".freeze

      # The stamp, then system context or any step. Every step is
      # uncorrelated with the outer row — the id and column steps compare the
      # row's column against the set of ids the holder's rows name, the
      # type-level step is a bare EXISTS — so Postgres evaluates each once
      # per query (an InitPlan, a hashed SubPlan) instead of once per row.
      # The 0.8.0 policy correlated one EXISTS on `IS NULL OR = t.id` and
      # re-ran it for every row of the table, seconds against a holder with
      # thousands of rows; this shape is milliseconds.
      def using(t, reach, wildcard, db)
        steps = [SYSTEM]
        steps << type_level_step(reach[:id], db) if wildcard
        reach.each { |column, types| steps << column_step(t, column, types, db) }
        "  #{STAMP}\n  AND (\n    #{steps.join("\n    OR ")}\n  )"
      end

      # `select` from the holder's compiled rows matching `where`, the two
      # identity halves as a UNION ALL rather than an OR inside one WHERE, so
      # each half can walk idx_sa_auth_by_current_user on its own.
      def holdings(select, where)
        [INTERNAL_USER, EXTERNAL_USER].map { |user|
          "SELECT #{select} FROM super_auth_authorizations a WHERE #{where} AND #{user}"
        }.join(" UNION ALL ")
      end

      def type_level_where(types, db)
        "a.resource_external_type IN (#{types.map { |type| db.literal(type) }.join(', ')}) AND a.resource_external_id IS NULL"
      end

      def per_record_where(types, db)
        "a.resource_external_type IN (#{types.map { |type| db.literal(type) }.join(', ')}) AND a.resource_external_id IS NOT NULL"
      end

      def type_level_step(types, db)
        "EXISTS (#{holdings('1', type_level_where(types, db))})"
      end

      def column_step(t, column, types, db)
        "#{t}.#{db.literal(Sequel.identifier(column.to_s))} IN (#{holdings('a.resource_external_id', per_record_where(types, db))})"
      end

      # The policy's comment: version, reach and wildcard as JSON with the
      # keys in one fixed order, so current? compares strings.
      def comment(reach, wildcard)
        JSON.generate("super_auth" => POLICY_VERSION, "reach" => reach.to_h { |column, types| [column.to_s, types] }, "wildcard" => wildcard)
      end

      # ---- Preflight.

      # Refuses, before any DDL, a reach column the policy could not compare:
      # one the table lacks, or one outside the type family of
      # super_auth_authorizations.resource_external_id. CREATE POLICY refuses
      # the second on its own, with "operator does not exist: integer =
      # character varying" and no hint that external_id_type is the setting
      # that decides the other side.
      def preflight!(table, reach, db)
        reference = column_types(:super_auth_authorizations, [:resource_external_id], db)[:resource_external_id]
        unless reference
          raise SuperAuth::Error, "super_auth_authorizations.resource_external_id does not exist; run the super_auth migrations before enable"
        end
        columns = column_types(table, reach.keys, db)
        setting = "SuperAuth.external_id_type is #{SuperAuth.external_id_type.inspect}"
        reach.each_key do |column|
          type = columns[column]
          unless type
            through = column == :id ? "reaches rows by it" : "reaches rows through it as a parent: column holding the id of the record a row belongs to"
            raise SuperAuth::Error, "#{table} has no column #{column}, and the policy #{through}; " \
              "super_auth_authorizations.resource_external_id is #{reference[1]} (#{setting})"
          end
          next if same_family?(type[0], reference[0])
          raise SuperAuth::Error, "#{table}.#{column} is #{type[1]} and super_auth_authorizations.resource_external_id is #{reference[1]}; " \
            "the policy compares them with no cast, so they must be the same type, both integer types or both text types. " \
            "#{setting}: set it to the type of your tables' ids before running the super_auth migrations, " \
            "or alter the four external id columns to match"
        end
      end

      # { column => [internal type name, SQL type name] } for the columns the
      # table has among `columns`. Raises for a table that does not exist —
      # a missing table would otherwise read as every column missing.
      def column_types(table, columns, db)
        rel = db.literal(Sequel.identifier(table.to_s))
        unless db.get(Sequel.function(:to_regclass, rel))
          raise SuperAuth::Error, "table #{table} does not exist"
        end
        db.fetch(<<~SQL).to_h { |row| [row[:name].to_sym, [row[:internal], row[:sql]]] }
          SELECT a.attname AS name, t.typname AS internal, format_type(a.atttypid, a.atttypmod) AS sql
          FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
          WHERE a.attrelid = to_regclass(#{db.literal(rel)}) AND a.attnum > 0 AND NOT a.attisdropped
            AND a.attname IN (#{columns.map { |column| db.literal(column.to_s) }.join(', ')})
        SQL
      end

      def same_family?(a, b)
        a == b || TYPE_FAMILIES.any? { |family| family.include?(a) && family.include?(b) }
      end

      # ---- The catalogue: what is installed on a table.

      def policies(db, table: nil)
        scope = table ? "AND c.oid = to_regclass(#{db.literal(db.literal(Sequel.identifier(table.to_s)))})" : ""
        db.fetch(<<~SQL).all
          SELECT c.relname AS "table", p.polname AS name,
                 obj_description(p.oid, 'pg_policy') AS comment,
                 pg_get_expr(p.polqual, p.polrelid) AS qual,
                 c.relrowsecurity AS enabled, c.relforcerowsecurity AS forced
          FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
          WHERE p.polname IN (#{POLICY_NAMES.map { |name| db.literal(name) }.join(', ')}) #{scope}
        SQL
      end

      # The table's policy under the current name, or nil.
      def policy(table, db)
        policies(db, table: table).find { |row| row[:name] == POLICY }
      end

      # The comment as a Hash, or nil for no comment or one that is not the
      # gem's JSON.
      def parse(comment)
        parsed = JSON.parse(comment.to_s)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def version(comment)
        parse(comment)&.dig("super_auth")
      end

      # Reach and wildcard from the policy's comment, the reach re-normalised
      # so it is the same frozen shape enable built from.
      def metadata(table, db)
        row = policy(table, db)
        raise SuperAuth::Error, "#{table} has no #{POLICY} policy; run SuperAuth::RLS.enable first" unless row
        parsed = parse(row[:comment])
        stored = parsed && parsed["reach"]
        unless parsed && parsed["super_auth"] == POLICY_VERSION && stored.is_a?(Hash) && stored.key?("id") && [true, false].include?(parsed["wildcard"])
          raise SuperAuth::Error, "the #{POLICY} policy on #{table} was not built by this version of enable (policy version #{POLICY_VERSION}); re-run SuperAuth::RLS.enable"
        end
        parent = stored.reject { |column, _| column == "id" }.map { |column, types| { column: column, resource_type: types } }
        { reach: Reach.normalize(resource_type: stored["id"], parent: parent), wildcard: parsed["wildcard"] }
      end

      # ---- coverage and explain.

      # Runs the block in a transaction whose reads of the protected table
      # are not filtered by the asserted identity, where the role allows it:
      # system context through super_auth_system() when the calling role may
      # execute it and is not one Postgres exempts from row security anyway
      # (a superuser or BYPASSRLS role reads everything, and the function
      # refuses it). A role with neither runs as it is, and its reads see only
      # what its identity sees. Joins an enclosing transaction and puts its
      # identity back at the end, as `as` does, since the block re-points the
      # identity settings.
      def reading(db)
        enclosing = db.in_transaction? ? identity(db) : nil
        db.transaction do
          db.get(Sequel.function(:super_auth_system)) if bypass_available?(db)
          begin
            yield
          ensure
            restore(enclosing, db) if enclosing
          end
        end
      end

      def bypass_available?(db)
        db.get(Sequel.lit(<<~SQL))
          COALESCE(has_function_privilege(current_user, to_regprocedure('super_auth_system()'), 'EXECUTE'), false)
          AND NOT (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user)
        SQL
      end

      # Points the three identity settings at one holder — user_id,
      # user_external_id, user_external_type — so the policy's own predicate
      # matches that holder's rows. System context, when asserted, stays.
      def as_holder(values, db)
        db.dataset.get(SETTINGS[0, 3].zip(values).each_with_index.map { |(name, value), i| Sequel.function(:set_config, name, value.to_s, true).as(:"s#{i}") })
      end

      def holdings_of(where, db)
        db.fetch(holdings("a.*", where)).all
      end

      def tag(step, rows)
        rows.map { |row| row.merge(step: step) }
      end

      # The distinct identities holding a compiled row matching `where`.
      def holders_of(where, db)
        db.fetch("SELECT DISTINCT a.user_id, a.user_external_id, a.user_external_type FROM super_auth_authorizations a WHERE #{where} ORDER BY 1, 2, 3")
          .map { |row| [row[:user_id], row[:user_external_id], row[:user_external_type]] }
      end

      def holder_hash(values)
        { user_id: values[0], user_external_id: values[1], user_external_type: values[2] }
      end

      # Count and up to 20 ids of the table's rows matching `where`.
      def sample(t, where, db)
        ds = db[t].where(Sequel.lit(where))
        { count: ds.count, ids: ds.order(:id).limit(20).select_map(:id) }
      end

      def loss(t, tq, reach, db)
        holders_of(type_level_where(reach[:id], db), db).filter_map do |holder|
          as_holder(holder, db)
          unreached = ["NOT (#{column_step(tq, :id, reach[:id], db)})"]
          Reach.parents(reach).each do |column, types|
            unreached << "(#{tq}.#{db.literal(Sequel.identifier(column.to_s))} IS NULL OR NOT (#{column_step(tq, column, types, db)}))"
          end
          entry = sample(t, unreached.join(" AND "), db)
          { holder: holder_hash(holder), **entry } if entry[:count] > 0
        end
      end

      def widening(t, tq, reach, wildcard, db)
        parents = Reach.parents(reach)
        return [] if parents.empty?
        holders_of(per_record_where(parents.values.flatten.uniq, db), db).filter_map do |holder|
          as_holder(holder, db)
          via_parent = parents.map { |column, types| column_step(tq, column, types, db) }.join(" OR ")
          where = "(#{via_parent}) AND NOT (#{column_step(tq, :id, reach[:id], db)})"
          where += " AND NOT #{type_level_step(reach[:id], db)}" if wildcard
          entry = sample(t, where, db)
          { holder: holder_hash(holder), **entry } if entry[:count] > 0
        end
      end

      def orphaned_rows(reach, db)
        types = reach.values.flatten.uniq.map { |type| db.literal(type) }.join(", ")
        where = <<~SQL
          a.resource_external_type IN (#{types})
          AND NOT EXISTS (
            SELECT 1 FROM super_auth_resources r
            WHERE r.id = a.resource_id
              AND r.external_type = a.resource_external_type
              AND r.external_id IS NOT DISTINCT FROM a.resource_external_id
          )
        SQL
        groups = db.fetch(<<~SQL).all
          SELECT a.resource_external_type AS type, (a.resource_external_id IS NULL) AS type_level, count(*) AS count
          FROM super_auth_authorizations a WHERE #{where}
          GROUP BY 1, 2 ORDER BY 1, 2
        SQL
        groups.map do |group|
          ids = db.fetch(<<~SQL).map(:id)
            SELECT DISTINCT a.resource_id AS id FROM super_auth_authorizations a
            WHERE #{where} AND a.resource_external_type = #{db.literal(group[:type])}
              AND (a.resource_external_id IS NULL) = #{group[:type_level]}
            ORDER BY 1 LIMIT 20
          SQL
          { type: group[:type], type_level: group[:type_level], count: group[:count], ids: ids }
        end
      end

      def deletable_nodes(reach, db)
        where = <<~SQL
          r.external_type IN (#{reach[:id].map { |type| db.literal(type) }.join(', ')})
          AND r.external_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM super_auth_edges e WHERE e.resource_id = r.id AND e.user_id IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM super_auth_resources child WHERE child.parent_id = r.id)
        SQL
        db.fetch("SELECT r.external_type AS type, count(*) AS count FROM super_auth_resources r WHERE #{where} GROUP BY 1 ORDER BY 1").map do |group|
          ids = db.fetch("SELECT r.id FROM super_auth_resources r WHERE #{where} AND r.external_type = #{db.literal(group[:type])} ORDER BY r.id LIMIT 20").map(:id)
          { type: group[:type], count: group[:count], ids: ids }
        end
      end

      # ---- Installation.

      # What any runtime role needs on the gem's own tables: the policies read
      # super_auth_authorizations as the querying role, and the user models'
      # system? reads super_auth_users. Granting PUBLIC makes enable the only
      # setup step; a deployment that wants these tables private can REVOKE
      # from PUBLIC and grant per role.
      def grant_runtime_reads(db)
        db.run "GRANT SELECT ON super_auth_authorizations, super_auth_users TO PUBLIC"
      end

      # Refuses an identity assertion from a role Postgres exempts from row
      # security: the policies would apply to nobody while everything looked
      # enforced. Checks the effective role, so a superuser session that has
      # SET ROLE to an application role passes.
      SUPERUSER_GUARD = <<~SQL.freeze
        IF (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
          RAISE EXCEPTION 'super_auth: role % is a superuser or has BYPASSRLS, so row-level security does not apply to it and asserting an identity would protect nothing. Connect as a regular role.', current_user
            USING ERRCODE = 'invalid_authorization_specification';
        END IF;
      SQL

      # Two shared functions per database; clients assert identity by calling
      # one of them inside their transaction. CREATE OR REPLACE keeps enable
      # idempotent. The pre-0.5 four-argument super_auth_become carried the
      # system bypass as its last parameter; a REPLACE with a different
      # signature would leave that overload in place, so it is dropped.
      def create_functions(db)
        db.run "DROP FUNCTION IF EXISTS super_auth_become(text, text, text, boolean)"
        db.run <<~SQL
          CREATE OR REPLACE FUNCTION super_auth_become(
            user_external_id text DEFAULT NULL,
            user_external_type text DEFAULT NULL,
            user_id text DEFAULT NULL
          ) RETURNS void LANGUAGE plpgsql AS $$
          BEGIN
            #{SUPERUSER_GUARD}
            PERFORM set_config('super_auth.user_id',            COALESCE(user_id, ''), true),
                    set_config('super_auth.user_external_id',   COALESCE(user_external_id, ''), true),
                    set_config('super_auth.user_external_type', COALESCE(user_external_type, ''), true),
                    set_config('super_auth.system',             '', true),
                    set_config('super_auth.xid',                pg_current_xact_id()::text, true);
          END
          $$;
        SQL
        db.run <<~SQL
          CREATE OR REPLACE FUNCTION super_auth_system() RETURNS void LANGUAGE plpgsql AS $$
          BEGIN
            #{SUPERUSER_GUARD}
            PERFORM set_config('super_auth.user_id',            '', true),
                    set_config('super_auth.user_external_id',   '', true),
                    set_config('super_auth.user_external_type', '', true),
                    set_config('super_auth.system',             'true', true),
                    set_config('super_auth.xid',                pg_current_xact_id()::text, true);
          END
          $$;
        SQL
        # Bypass is opt-in per role: GRANT EXECUTE ON FUNCTION super_auth_system() TO <role>.
        db.run "REVOKE EXECUTE ON FUNCTION super_auth_system() FROM PUBLIC"
      end

      # super_auth_become's three arguments for `user`: a SuperAuth user
      # record goes by user_id, any other object by id and class name, nil by
      # nothing, an identity no authorization matches.
      def become_args(user)
        if user.nil?
          [nil, nil, nil]
        elsif SuperAuth.internal_user?(user)
          [nil, nil, user.id.to_s]
        else
          [user.id.to_s, user.class.name, nil]
        end
      end

      # The five transaction-local settings the policies read, in one order.
      SETTINGS = %w[
        super_auth.user_id super_auth.user_external_id super_auth.user_external_type
        super_auth.system super_auth.xid
      ].freeze

      def identity(db)
        db.dataset.get(SETTINGS.each_with_index.map { |name, i| Sequel.function(:current_setting, name, true).as(:"s#{i}") })
      end

      # Writes the settings back directly: the values were read from this same
      # transaction, so the stamp is still the current one, and no role is
      # granted anything it could not already set.
      def restore(values, db)
        db.dataset.get(SETTINGS.zip(values).each_with_index.map { |(name, value), i| Sequel.function(:set_config, name, value.to_s, true).as(:"s#{i}") })
      rescue Sequel::DatabaseError
        # The block aborted the transaction; its rollback discards the settings.
      end

      def postgres!(db)
        return if db.database_type == :postgres
        raise SuperAuth::Error, "SuperAuth::RLS requires Postgres (got #{db.database_type})"
      end
    end
  end
end
