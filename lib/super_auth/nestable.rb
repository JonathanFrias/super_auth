module SuperAuth::Nestable

  def self.included(base)
    base.extend ClassMethods

    base.plugin :rcte_tree, {
      cte_name: base.cte_name(base),
      ancestors: {
        dataset: -> { base.cte(self.id, :asc) }
      },
      descendants: {
        dataset: -> { base.cte(self.parent_id, :desc) }
      }
    }

    base.dataset_module do
      def roots
        self.where(parent_id: nil)
      end

      def trees
        model.cte(nil, :desc)
      end
    end
  end

  # A node may not be its own parent, nor sit under one of its own
  # descendants: either closes a parent_id cycle. The pair CTEs terminate on
  # one (UNION), so a cycle does not hang a compile; it does something
  # quieter and worse. Every node in a cycle is an ancestor of every other,
  # so a grant on any of them reaches all of their subtrees — a container
  # pointed at one of its own children turned a single per-record read into
  # the container's whole membership, with nothing raised anywhere. Checked
  # only when parent_id changes, by walking UP from the new parent: that is
  # one row per level however large the subtree, and unlike the descendant
  # walk it does not stop at a type-level node
  # (SuperAuth::Resource.descend_from), so a cycle through one is caught too.
  # assert_acyclic! covers writes that bypass the model.
  def validate
    super
    return if parent_id.nil? || !changed_columns.include?(:parent_id)

    if parent_id == id
      errors.add(:parent_id, "cannot be the node itself")
    elsif !new? && model.ancestor_pairs(of: [parent_id]).where(ancestor_id: id).count > 0
      errors.add(:parent_id, "is inside the node's own subtree, which would close a cycle")
    end
  end

  # A deleted node takes its compiled rows and its edges with it, in the
  # transaction that deletes the row: runtime reads only the compiled table,
  # and a row naming a node that no longer exists would keep granting until
  # the next compile. Children are not touched. The foreign key refuses to
  # orphan them, and whether they are re-rooted or deleted is the caller's
  # decision (the editor re-roots them, deliberately). Rows compiled through
  # this node for its descendants stay until the next compile, as after any
  # other revocation.
  def before_destroy
    super
    column = :"#{model.singularize}_id"
    SuperAuth::Authorization.where(column => id).delete
    SuperAuth::Edge.where(column => id).delete
  end

  module ClassMethods
    # Helper method to get the appropriate string cast type for the database
    def string_cast_type
      case SuperAuth.db.database_type
      when :mysql, :mysql2
        :char
      else
        :text
      end
    end

    # Cast type for the anchor row of the path CTEs. MySQL types a recursive
    # CTE's columns from the anchor SELECT alone, so a bare CAST(id AS CHAR)
    # makes the path column varchar(11) and every deeper level overflows it
    # ("Data too long for column"). :text is unbounded elsewhere.
    def path_cast_type
      case SuperAuth.db.database_type
      when :mysql, :mysql2
        "char(4000)"
      else
        :text
      end
    end

    # Every node paired with itself and each of its ancestors, as
    # (descendant_id, ancestor_id). The path strategies join these integer
    # pairs on equality; matching ids inside the comma-separated path strings
    # with LIKE forced a nested loop no planner could index, and compile time
    # grew roughly cubically with the graph.
    #
    # Both pair CTEs recurse with UNION rather than UNION ALL. The pair
    # relation is finite (at most n² rows), so UNION stops as soon as a step
    # produces nothing new, which on a parent_id cycle is the first time round;
    # UNION ALL re-derives the same pairs forever and compile! never returns.
    # On a valid tree no step repeats a pair, so the output is the same.
    #
    # `of:` (a dataset or an array of ids) restricts the anchor to those
    # nodes, so only their ancestor chains are walked: one row per level.
    def ancestor_pairs(of: nil)
      table = pluralize
      name = :"#{singularize}_ancestor_pairs"
      anchor = db[table].select(Sequel[:id].as(:descendant_id), Sequel[:id].as(:ancestor_id))
      anchor = anchor.where(id: of) unless of.nil?
      step = db[name].join(table, id: :ancestor_id).exclude(Sequel[table][:parent_id] => nil).
        select(Sequel[name][:descendant_id], Sequel[table][:parent_id])
      db.from(name).with_recursive(name, anchor, step, args: [:descendant_id, :ancestor_id], union_all: false)
    end

    # Every node paired with itself and each of its descendants, as
    # (ancestor_id, descendant_id). Granting a role grants its whole subtree.
    #
    # `of:` (a dataset or an array of ids) restricts the anchor to those nodes,
    # so only their subtrees are walked. Groups and roles are few and the
    # whole table is cheap; resources are one row per protected record, and an
    # unanchored CTE materialises every pair of the whole table once per
    # strategy that joins it.
    #
    # The recursive step joins the parent row only when the model puts a
    # condition on it (descend_from); the pair CTE itself never carries more
    # than the two ids.
    def descendant_pairs(of: nil)
      table = pluralize
      name = :"#{singularize}_descendant_pairs"
      parent = :"#{singularize}_parent"
      anchor = db[table].select(Sequel[:id].as(:ancestor_id), Sequel[:id].as(:descendant_id))
      anchor = anchor.where(id: of) unless of.nil?
      step = db[name].join(table, parent_id: :descendant_id).
        select(Sequel[name][:ancestor_id], Sequel[table][:id])
      if (condition = descend_from(parent))
        step = step.join(Sequel[table].as(parent), id: Sequel[name][:descendant_id]).where(condition)
      end
      db.from(name).with_recursive(name, anchor, step, args: [:ancestor_id, :descendant_id], union_all: false)
    end

    # Whether descendant_pairs continues below a node: a Sequel condition on
    # the parent row, addressed through the alias `parent`, or nil to descend
    # from every node. Groups and roles descend from everything.
    # SuperAuth::Resource stops at a type-level node, so a grant on one yields
    # its own row and nothing beneath it on every path that reads the walk.
    def descend_from(parent)
      nil
    end

    # Every node some root reaches, walking parent_id downward from the rows
    # that have none. On a valid forest that is the whole table; what it
    # misses is exactly the nodes on or under a parent_id cycle (and, where
    # no foreign key stands, a node whose parent is missing). No path
    # columns, unlike trees: this runs over the whole resources table before
    # every compile, and needs only the ids.
    def rooted
      table = pluralize
      name = :"rooted_#{table}"
      anchor = db[table].where(parent_id: nil).select(:id)
      step = db[name].join(table, parent_id: :id).select(Sequel[table][:id])
      db.from(name).with_recursive(name, anchor, step, args: [:id], union_all: false)
    end

    # Refuses a table with a parent_id cycle in it, naming the nodes no root
    # reaches. compile! calls this for groups, roles and resources before
    # touching the compiled table, because a cycle does not fail a compile:
    # the walks terminate, and every node in the cycle is an ancestor of
    # every other, so a grant on any of them silently reaches all of their
    # subtrees. validate refuses the shape at the model; this catches it
    # after a write that went around the model.
    def assert_acyclic!
      unreachable = dataset.exclude(id: rooted).select_order_map(:id)
      return if unreachable.empty?

      raise SuperAuth::Error, "#{pluralize} has a parent_id cycle: node(s) #{unreachable.join(', ')} " \
        "cannot be reached from any root. Point one of them at a root, or at no parent, and recompile."
    end

    def cte(id = nil, direction = :desc)
      model = self
      cte_name = model.cte_name
      base_ds = model.select_all(pluralize)

      case direction
      when :asc
        base_ds = base_ds.where(id: id)

        recursive_ds = model
          .join(cte_name, parent_id: :id)
          .select_all(pluralize)
        base_ds, recursive_ds = with_ascending_paths(base_ds, recursive_ds, cte_name)
      when :desc
        if id
          base_ds = base_ds.where(id: id)
        else
          base_ds = base_ds.where(parent_id: id)
        end

        recursive_ds = model
          .join(cte_name, id: :parent_id)
          .select_all(pluralize(model))

        base_ds, recursive_ds = with_descending_paths(base_ds, recursive_ds, cte_name)
      end

      model.from(cte_name)
        .with_recursive(cte_name, base_ds, recursive_ds)
    end

    def with_descending_paths(base_ds, recursive_ds, cte_name)
      [
        base_ds.select_append(
          Sequel[table_name][:id].cast(path_cast_type).as(base_path)
        ).select_append(Sequel[table_name][:name].cast(path_cast_type).as(base_name_path)),

        recursive_ds.select_append(
          Sequel.function(:concat,
            Sequel[cte_name][base_path].cast(string_cast_type),
            Sequel.lit("','"),
            Sequel[pluralize][:id].cast(string_cast_type),
          ).as(base_path)
        ).select_append(
           Sequel.function(:concat,
            Sequel[cte_name][base_name_path],
            Sequel.lit("','"),
            Sequel[table_name][:name],
          ).as(base_name_path)
        )
      ]
    end

    def with_ascending_paths(base_ds, recursive_ds, cte_name)
      [
        base_ds.select_append(Sequel[table_name][:id].cast(path_cast_type).as(base_path)).select_append(Sequel[table_name][:name].cast(path_cast_type).as(base_name_path)),
        recursive_ds.select_append(
          Sequel.function(:concat,
            Sequel[table_name][:id].cast(string_cast_type),
            Sequel.lit("','"),
            Sequel[cte_name][base_path].cast(string_cast_type),
          ).as(base_path)
        ).select_append(
           Sequel.function(:concat,
            Sequel[table_name][:name],
            Sequel.lit("','"),
            Sequel[cte_name][base_name_path],
          ).as(base_name_path)
        )
      ]
    end

    # See: ActiveSupport::Inflector.demodulize
    def demodularize(base = self)
      if i = base.name.rindex("::")
        base.name[(i + 2), base.name.length]
      else
        base.name
      end
    end

    def pluralize(base = self)
      "super_auth_#{demodularize(base).downcase}s".to_sym
    end

    def singularize(base = self)
      demodularize(base).downcase.to_sym
    end

    def cte_name(base = self)
      "super_auth_#{pluralize(base)}_cte".to_sym
    end

    def base_path(base = self)
      "#{singularize(base)}_path".to_sym
    end

    def base_name_path(base = self)
      "#{singularize(base)}_name_path".to_sym
    end
  end
end
