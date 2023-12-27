class SuperAuth::Group < Sequel::Model(:groups)
  # plugin :tree, single_root: true
  plugin :rcte_tree, {
    cte_name: :groups_cte,
    ancestors: {
      dataset: -> { SuperAuth::Group.group_cte(model, :groups_cte, :asc, self.id) }
    },
    descendants: {
      dataset: -> { SuperAuth::Group.group_cte(model, :groups_cte, :desc, self.parent_id) }
    }
  }

  def self.group_cte(model, cte_name, direction = :desc, id = nil)
    base_ds = model.select_all(:groups)

    case direction
    when :asc
      base_ds = base_ds.where(id: id)

      recursive_ds = model
        .join(cte_name, parent_id: :id)
        .select_all(:groups)
      base_ds, recursive_ds = with_ascending_paths(base_ds, recursive_ds, :groups_cte)
    when :desc
      base_ds = base_ds.where(parent_id: id)

      recursive_ds = model
        .join(cte_name, id: :parent_id)
        .select_all(:groups)

      base_ds, recursive_ds = with_descending_paths(base_ds, recursive_ds, :groups_cte)
    end

    model.from(cte_name)
      .with_recursive(cte_name, base_ds,recursive_ds)
  end

  def self.with_descending_paths(base_ds, recursive_ds, cte_name)
    [
      base_ds.select_append { cast(id.as(:text)).as(:group_path) }.select_append { name.as(:group_name_path) },
      recursive_ds.select_append(
        Sequel.function(:concat,
          Sequel.function(:cast, Sequel[cte_name][:group_path].as(:text)),
          Sequel.lit("','"),
          Sequel.function(:cast, Sequel[:groups][:id].as(:text)),
        ).as(:group_path)
      ).select_append(
         Sequel.function(:concat,
          Sequel[cte_name][:group_name_path],
          Sequel.lit("','"),
          Sequel[:groups][:name],
        ).as(:group_name_path)
      )
    ]
  end

  def self.with_ascending_paths(base_ds, recursive_ds, cte_name)
    [
      base_ds.select_append { cast(id.as(:text)).as(:group_path) }.select_append { name.as(:group_name_path) },
      recursive_ds.select_append(
        Sequel.function(:concat,
          Sequel.function(:cast, Sequel[:groups][:id].as(:text)),
          Sequel.lit("','"),
          Sequel.function(:cast, Sequel[cte_name][:group_path].as(:text)),
        ).as(:group_path)
      ).select_append(
         Sequel.function(:concat,
          Sequel[:groups][:name],
          Sequel.lit("','"),
          Sequel[cte_name][:group_name_path],
        ).as(:group_name_path)
      )
    ]
  end

  dataset_module do
    def roots
      self.where(parent_id: nil)
    end

    def trees
      SuperAuth::Group.group_cte(model, :groups_cte, :desc)
    end
  end
end
