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
    # container. The type-level grant is a supported, permanent primitive —
    # "this principal may act on every record of a type" has no cheaper
    # spelling — and it is flat: what it may not do is join the tree.
    def wildcards
      exclude(external_type: nil).where(external_id: nil)
    end

    # The node registered for one record: the pair every host helper looks
    # up before it grants, revokes or labels. It refuses a nil id rather than
    # answering, because where(external_type: type, external_id: nil) is not
    # "no node" — it IS the type-level node for that type, and a helper called
    # with an unset foreign key would otherwise act on the grant that covers
    # every record of the type.
    def record(type, id)
      if id.nil?
        raise SuperAuth::Error, "SuperAuth::Resource.record(#{type.to_s.inspect}, nil): the id is nil. " \
          "A node with an external_type and no external_id is the type-level node for every #{type} record, " \
          "not the node for one of them; pass the record's id, or use wildcards for the type-level node."
      end

      first(external_type: type.to_s, external_id: id)
    end

    # The recursive step of descendant_pairs stops at a type-level node. A
    # per-record node nested under one would otherwise receive the
    # type-level node's grants: one accidental parent_id, and a grant on
    # "every Claim" also compiled a row for every claim node beneath it, on
    # every path that reads the walk — including a host that reads
    # Edge.authorizations directly and never calls compile!, where
    # assert_compilable! does not run. The walk still anchors on the node a
    # grant names, so a granted type-level node yields its own (type, NULL)
    # row and nothing else; join_resource_subtree drops the other direction,
    # a type-level node reached as a descendant.
    def descend_from(parent)
      Sequel.|({ Sequel[parent][:external_type] => nil }, Sequel.~(Sequel[parent][:external_id] => nil))
    end

    # "Type-level nodes are flat." compile! calls this before touching the
    # compiled table, so a refused compile leaves the previous rows in place.
    # The walk and the join above make the shape harmless; this makes it
    # loud, because nobody means it. A type-level node with a parent looks
    # like a container grant that reaches every record of a type, and one
    # with children looks like a container whose children can only be
    # reached through a grant that already covers them. One query: the
    # type-level nodes that have a parent, or that some node names as its
    # parent.
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
  end
end
