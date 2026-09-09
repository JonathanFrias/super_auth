class SuperAuth::Authorization < Sequel::Model(:super_auth_authorizations)
  # Clears and repopulates the compiled table from the current graph, inside
  # one transaction, and returns the row count. Row by row, like
  # SuperAuth::ActiveRecord::Authorization.compile!; a single INSERT ... SELECT
  # is a separate change. Runtime enforcement (ByCurrentUser, the RLS policies)
  # reads only this table, so every edit to the graph is inert until this runs.
  # The wildcard guard runs first, before the delete, so a refused compile
  # leaves the previous rows in place rather than an empty table; the
  # deprecation notice comes after the commit, for a compile that happened.
  #
  # Postgres JIT-compiles the union's expressions on every run: 539 LLVM
  # functions, 1.6-2.2s of optimisation and emission for a query that then
  # executes in milliseconds. SET LOCAL scopes the switch to this transaction,
  # so nothing leaks to the pooled connection.
  def self.compile!
    count = db.transaction do
      db.run "SET LOCAL jit = off" if db.database_type == :postgres
      SuperAuth::Resource.assert_compilable!
      dataset.delete
      SuperAuth::Edge.authorizations.each { |row| dataset.insert(row) }
      dataset.count
    end
    SuperAuth::Resource.warn_deprecated_wildcards
    count
  end
end
