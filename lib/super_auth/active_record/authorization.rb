class SuperAuth::ActiveRecord::Authorization < ActiveRecord::Base
  self.table_name = 'super_auth_authorizations'

  class << self
    # Returns all computed authorization paths as Authorization AR objects.
    # These can be saved directly to the super_auth_authorizations table.
    def from_graph
      from("(#{SuperAuth::Edge.authorizations.sql}) as super_auth_authorizations".squish)
    end

    # Clears and repopulates the authorizations table from the current graph
    # with one INSERT ... SELECT on this connection, and returns the row
    # count; see SuperAuth::Authorization.compile!. The guards run before the
    # delete, so a refused compile leaves the previous rows in place.
    def compile!
      transaction do
        # Sequel runs on this transaction's connection (sequel-activerecord_connection),
        # so the JIT switch lands in it; see SuperAuth::Authorization.compile!.
        SuperAuth.db.run "SET LOCAL jit = off" if SuperAuth.db.database_type == :postgres
        SuperAuth::Authorization.assert_compilable!
        delete_all
        connection.execute(
          SuperAuth.db[:super_auth_authorizations].insert_sql(
            SuperAuth::Edge::AUTHORIZATION_COLUMNS, SuperAuth::Authorization.compile_source
          )
        )
        count
      end
    end
  end
end
