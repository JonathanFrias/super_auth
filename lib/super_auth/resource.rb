class SuperAuth::Resource < Sequel::Model(:super_auth_resources)
  # Resources nest like groups and roles: a grant on a node reaches the node
  # and every node under it (SuperAuth::Edge.join_resource_subtree). No
  # unrestrict_primary_key, unlike those two: it exists for the ActiveRecord
  # twins' descendants_dataset, which builds a Sequel model with an id, and
  # the ActiveRecord Resource deliberately has none — nothing at runtime
  # walks a resource tree.
  include SuperAuth::Nestable

  class << self
    # A node with an external_type and no external_id is a type-level
    # (wildcard) node: at runtime it means every record of that type, present
    # and future (the ByCurrentUser type_level branch, the policy's
    # `resource_external_id IS NULL OR` clause). A node with neither is a
    # container. Wildcards are deprecated (see warn_deprecated_wildcards) but
    # still the only way to authorize INSERT under row-level security, so they
    # stay; what they may not do is join the tree.
    def wildcards
      exclude(external_type: nil).where(external_id: nil)
    end

    # "Wildcard nodes are flat." compile! calls this before touching the
    # compiled table, so a refused compile leaves the previous rows in place.
    # A wildcard with a parent would compile to a (type, NULL) row reachable
    # through every ancestor's grants — one edge to a container silently
    # granting every record of a type — and a wildcard with children would
    # make the children unreachable except through a grant that already covers
    # them; neither is a shape anyone means. One query: the wildcards that
    # have a parent, or that some node names as its parent.
    def assert_compilable!
      parents = dataset.exclude(parent_id: nil).select(:parent_id)
      nested = wildcards.where(Sequel.|(Sequel.~(parent_id: nil), { id: parents })).select_order_map(:id)
      return if nested.empty?

      raise SuperAuth::Error, "Wildcard resource nodes must be flat, but wildcard node(s) #{nested.join(', ')} " \
        "have a parent or children. A resource node with an external_type and no external_id is a wildcard " \
        "for every record of that type, not a container: nested in the tree it would compile to a row that " \
        "reaches every record of its type through the tree. Move each to the root with no children, or give " \
        "it an external_id."
    end

    # One warning per compile, naming what exists, through SuperAuth.deprecator
    # so a Rails host's deprecation config (notify, raise, silence) applies.
    # A no-op when there are none, which is the common case.
    def warn_deprecated_wildcards
      rows = wildcards.order(:id).select_map([:id, :name])
      return if rows.empty?

      listed = rows.first(10).map { |id, name| "#{name} (#{id})" }
      listed << "..." if rows.size > 10
      SuperAuth.deprecator.warn(
        "#{rows.size} type-level (wildcard) resource node#{'s' if rows.size > 1} " \
        "(external_type set, external_id NULL): #{listed.join(', ')}. Wildcard nodes are deprecated. " \
        "They still work, and they remain the only way to authorize INSERT under row-level security; " \
        "the successor is a grant on a parent record. See the CHANGELOG."
      )
    end
  end
end
