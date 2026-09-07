class SuperAuth::Authorization < Sequel::Model(:super_auth_authorizations)
  # Clears and repopulates the compiled table from the current graph, inside
  # one transaction, and returns the row count. Row by row, like
  # SuperAuth::ActiveRecord::Authorization.compile!; a single INSERT ... SELECT
  # is a separate change. Runtime enforcement (ByCurrentUser, the RLS policies)
  # reads only this table, so every edit to the graph is inert until this runs.
  def self.compile!
    db.transaction do
      dataset.delete
      SuperAuth::Edge.authorizations.each { |row| dataset.insert(row) }
      dataset.count
    end
  end
end
