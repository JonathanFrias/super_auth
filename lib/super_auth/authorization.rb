class SuperAuth::Authorization < Sequel::Model(:super_auth_authorizations)
  class << self
    # Clears and repopulates the compiled table from the current graph, inside
    # one transaction, and returns the row count. One INSERT ... SELECT of
    # SuperAuth::Edge.authorizations, like the ActiveRecord twin: row by row
    # the same graph loaded at ~570 rows/s through the model, which at a
    # million rows is most of an hour in one held transaction, with every row
    # resident in Ruby. Runtime enforcement (ByCurrentUser, the RLS policies)
    # reads only this table, so every edit to the graph is inert until this
    # runs. The guards run first, before the delete, so a refused compile
    # leaves the previous rows in place rather than an empty table.
    #
    # Postgres JIT-compiles the union's expressions on every run: 539 LLVM
    # functions, 1.6-2.2s of optimisation and emission for a query that then
    # executes in milliseconds. SET LOCAL scopes the switch to this
    # transaction, so nothing leaks to the pooled connection.
    def compile!
      db.transaction do
        db.run "SET LOCAL jit = off" if db.database_type == :postgres
        assert_compilable!
        dataset.delete
        dataset.insert(SuperAuth::Edge::AUTHORIZATION_COLUMNS, compile_source)
        dataset.count
      end
    end

    # What must hold before the compiled table is touched, in the order the
    # failures are worst. A parent_id cycle in any tree table first: the
    # walks terminate on one, so it does not fail a compile — it quietly
    # makes every node in the cycle an ancestor of every other, and a grant
    # on any of them reaches all their subtrees. Then the resource tree's own
    # rule, that type-level nodes are flat.
    def assert_compilable!
      SuperAuth::Group.assert_acyclic!
      SuperAuth::Role.assert_acyclic!
      SuperAuth::Resource.assert_acyclic!
      SuperAuth::Resource.assert_compilable!
    end

    # The SELECT the compile inserts from. The eight timestamp columns travel
    # through the union as text (the MySQL collation reason in
    # SuperAuth::Edge.string_cast_type), and Postgres has no assignment cast
    # from text to timestamp: inserting the bare union there fails with
    # "column ... is of type timestamp ... but expression is of type text".
    # They are cast back on Postgres only. MySQL converts on assignment, and
    # SQLite's CAST(... AS timestamp) has NUMERIC affinity, which would keep
    # the "2026" of a date and drop the rest.
    def compile_source
      graph = SuperAuth::Edge.authorizations
      return graph unless db.database_type == :postgres

      columns = SuperAuth::Edge::AUTHORIZATION_COLUMNS.map do |column|
        column.end_with?("_at") ? Sequel.cast(column, :timestamp).as(column) : column
      end
      graph.from_self(alias: :graph).select(*columns)
    end
  end
end
