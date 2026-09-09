Sequel.migration do
  # Resources nest like groups and roles (2_groups.rb): same integer type as
  # the pk, deferrable only where supported. The index is skipped on MySQL
  # for the reason in 8_add_indexes_to_edges.rb — InnoDB indexes the foreign
  # key column itself and will not drop that index while the constraint
  # stands. Both branches compute database_type before alter_table: inside
  # the block self is the generator.
  up do
    is_postgres = database_type == :postgres
    is_mysql = [:mysql, :mysql2].include?(database_type)

    alter_table(:super_auth_resources) do
      if is_postgres
        add_foreign_key :parent_id, :super_auth_resources, deferrable: true, type: :integer
      else
        add_foreign_key :parent_id, :super_auth_resources, type: :integer
      end
      add_index :parent_id unless is_mysql
    end
  end

  # drop_foreign_key drops the constraint and then the column; MySQL refuses
  # to drop a column a constraint still depends on.
  down do
    is_mysql = [:mysql, :mysql2].include?(database_type)

    alter_table(:super_auth_resources) do
      drop_index :parent_id unless is_mysql
      drop_foreign_key :parent_id
    end
  end
end
