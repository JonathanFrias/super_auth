class SuperAuth::ActiveRecord::Authorization < ActiveRecord::Base
  self.table_name = 'super_auth_authorizations'

  class << self
    # Returns all computed authorization paths as Authorization AR objects.
    # These can be saved directly to the super_auth_authorizations table.
    def from_graph
      from("(#{SuperAuth::Edge.authorizations.sql}) as super_auth_authorizations".squish)
    end

    # Clears and repopulates the authorizations table from the current graph.
    def compile!
      transaction do
        delete_all
        from_graph.each { |auth| create!(auth.attributes.except("id")) }
      end
      count
    end
  end
end
