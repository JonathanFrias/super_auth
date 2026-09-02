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
    def ancestor_pairs
      table = pluralize
      name = :"#{singularize}_ancestor_pairs"
      anchor = db[table].select(Sequel[:id].as(:descendant_id), Sequel[:id].as(:ancestor_id))
      step = db[name].join(table, id: :ancestor_id).exclude(Sequel[table][:parent_id] => nil).
        select(Sequel[name][:descendant_id], Sequel[table][:parent_id])
      db.from(name).with_recursive(name, anchor, step, args: [:descendant_id, :ancestor_id])
    end

    # Every node paired with itself and each of its descendants, as
    # (ancestor_id, descendant_id). Granting a role grants its whole subtree.
    def descendant_pairs
      table = pluralize
      name = :"#{singularize}_descendant_pairs"
      anchor = db[table].select(Sequel[:id].as(:ancestor_id), Sequel[:id].as(:descendant_id))
      step = db[name].join(table, parent_id: :descendant_id).
        select(Sequel[name][:ancestor_id], Sequel[table][:id])
      db.from(name).with_recursive(name, anchor, step, args: [:ancestor_id, :descendant_id])
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
