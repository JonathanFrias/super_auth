# The reach map: which authorization rows admit a row of a protected table.
#
# Both layers take the same two keywords, resource_type: and parent:, and
# both ask the same question of every row: does the current user hold a
# compiled authorization that reaches it? A row is reached through its own
# id (a per-record grant, or a type-level grant on the class's own type) or
# through a column holding another record's id (a parent grant: the row's
# tenancy, read off the row itself). The reach map is that question in one
# shape, an ordered Hash from column to the types whose rows admit through
# it, with :id always the first step:
#
#   SuperAuth::Reach.normalize(
#     resource_type: "Claim",
#     parent: { column: :organization_id, resource_type: %w[Organization::Member Organization::Admin] })
#   # => { id: ["Claim"], organization_id: ["Organization::Member", "Organization::Admin"] }
#
# The RLS policy and the ByCurrentUser scope each emit one step per entry,
# and both build from this map rather than from the raw keywords so they
# cannot drift: an argument shape one layer accepted and the other rejected,
# or a column one saw and the other did not, is a row the ORM shows and the
# database hides, or the reverse, which is the dangerous direction. Every
# entry is a list because RLS must never be narrower than any tier's ORM
# scope over the same table: a table whose readers key on
# Organization::Member and whose writers on Organization::CaseWriter names
# both under the column, so the holder of one without the other is still
# admitted at the database.
#
# :id is refused as a parent column since it is the per-record step, already
# declared by resource_type:. A column declared twice is refused because the
# second entry would silently shadow the first; every type a column admits
# goes in one list.
module SuperAuth
  module Reach
    class << self
      def normalize(resource_type:, parent: nil)
        reach = { id: types(resource_type, "resource_type:") }
        entries(parent).each do |entry|
          unless entry.is_a?(Hash) && (entry.keys - %i[column resource_type]).empty?
            raise Error, "parent: must be a Hash {column:, resource_type:} or an Array of them, got #{entry.inspect}"
          end
          column = column_name(entry[:column])
          if reach.key?(column)
            raise Error, "parent: column #{column.inspect} is declared twice; list every type it admits under one entry"
          end
          reach[column] = types(entry[:resource_type], "parent: #{column} resource_type:")
        end
        reach.freeze
      end

      # The column steps alone, for the layer emitting one per parent and for
      # recording what a policy was built from.
      def parents(reach)
        reach.reject { |column, _| column == :id }
      end

      private

      def entries(parent)
        case parent
        when nil then []
        when Hash then [parent]
        when Array then parent
        else raise Error, "parent: must be a Hash {column:, resource_type:} or an Array of them, got #{parent.inspect}"
        end
      end

      def column_name(column)
        name = column.to_s if column.is_a?(Symbol) || column.is_a?(String)
        if name.nil? || name.empty?
          raise Error, "parent: column: must be a Symbol or String naming a column, got #{column.inspect}"
        end
        if name == "id"
          raise Error, "parent: column: :id is the per-record step, which resource_type: already declares; a parent is a column holding another record's id"
        end
        name.to_sym
      end

      # Frozen copies rather than freezing the caller's strings in place.
      def types(value, label)
        list = value.is_a?(Array) ? value : [value]
        unless !list.empty? && list.all? { |type| type.is_a?(String) && !type.empty? }
          raise Error, "#{label} must be a String or a non-empty Array of Strings, got #{value.inspect}"
        end
        list.uniq.map { |type| -type }.freeze
      end
    end
  end
end
