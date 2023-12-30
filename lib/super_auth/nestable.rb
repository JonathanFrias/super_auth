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
          Sequel.function(
            :cast,
            Sequel[table_name][:id].as(:text)
          ).as(base_path)
        ).select_append(Sequel[table_name][:name].as(base_name_path)),

        recursive_ds.select_append(
          Sequel.function(:concat,
            Sequel.function(:cast, Sequel[cte_name][base_path].as(:text)),
            Sequel.lit("','"),
            Sequel.function(:cast, Sequel[pluralize][:id].as(:text)),
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
        base_ds.select_append(Sequel.function(:cast, Sequel[table_name][:id].as(:text)).as(base_path)).select_append(Sequel[table_name][:name].as(:base_name_path)),
        recursive_ds.select_append(
          Sequel.function(:concat,
            Sequel.function(:cast, Sequel[table_name][:id].as(:text)),
            Sequel.lit("','"),
            Sequel.function(:cast, Sequel[cte_name][base_path].as(:text)),
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
      "#{demodularize(base).downcase}s".to_sym
    end

    def singularize(base = self)
      demodularize(base).downcase.to_sym
    end

    def cte_name(base = self)
      "#{pluralize(base)}_cte".to_sym
    end

    def base_path(base = self)
      "#{singularize(base)}_path".to_sym
    end

    def base_name_path(base = self)
      "#{singularize(base)}_name_path".to_sym
    end
  end
end