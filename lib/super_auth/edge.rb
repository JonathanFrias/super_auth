class SuperAuth::Edge < Sequel::Model(:super_auth_edges)
  plugin :dirty

  many_to_one :user
  many_to_one :group
  many_to_one :permission
  many_to_one :role
  many_to_one :resource

  # The columns of `authorizations`, in its order. compile! inserts the union
  # straight into super_auth_authorizations under this list, so it is the
  # contract between the five SELECTs below and the table: MySQL and Postgres
  # both need the column list, and the table has columns the union does not
  # fill (its own timestamps, the ActiveRecord migration's id).
  AUTHORIZATION_COLUMNS = %i[
    user_id user_name user_external_id user_external_type user_created_at user_updated_at
    group_id group_name group_path group_name_path group_parent_id group_created_at group_updated_at
    role_id role_name role_path role_name_path role_parent_id role_created_at role_updated_at
    permission_id permission_name permission_created_at permission_updated_at
    resource_id resource_name resource_external_id resource_external_type
  ].freeze

  class << self
    # The five strategies are UNIONed positionally. A column that is a real
    # text column in one strategy and CAST(NULL AS ...) in another must be cast
    # in every strategy: on MySQL the table collation and the connection
    # collation can differ, and a column meeting a NULL cast at the same
    # coercibility raises "Illegal mix of collations for operation 'UNION'".
    def string_cast_type
      case SuperAuth.db.database_type
      when :mysql, :mysql2
        :char
      else
        :text
      end
    end

    def integer_cast_type
      case SuperAuth.db.database_type
      when :mysql, :mysql2
        :signed
      else
        :bigint
      end
    end

    def authorizations
      users_groups_roles_permissions_resources
        .union(users_roles_permissions_resources)
        .union(users_groups_permissions_resources)
        .union(users_permissions_resources)
        .union(users_resources)
    end

    # Every resource node a grant reaches: each granted node paired with
    # itself and each of its descendants, as (ancestor_id, descendant_id).
    # Anchored on the ids that appear in edges rather than on the whole table.
    # Groups and roles are few, but resources are one row per protected
    # record, and the unanchored CTE materialises every pair of the table once
    # per strategy — 27s per strategy on MySQL at 300k resources, 0.025s
    # anchored — so the walk is sized by the grants, not by the table. On a
    # flat graph it is the identity relation and the compiled rows are exactly
    # what the previous pk join produced. The walk never descends from a
    # type-level node (Resource.descend_from): a granted (type, NULL) node
    # pairs with itself and nothing beneath it, on every path that reads this
    # relation, compile! or not.
    def resource_subtrees
      granted = db[:super_auth_edges].exclude(resource_id: nil).select(:resource_id)
      SuperAuth::Resource.descendant_pairs(of: granted)
    end

    # The last hop of every strategy: from the resource id on an edge to the
    # node it names and each node under it. The compiled row copies the
    # descendant's own columns, so containment is not inheritance — a node
    # keeps its own external_type — and the type-level tricks in ByCurrentUser
    # still hold. No resource path columns, unlike groups and roles: nothing at
    # runtime reads one, and super_auth_authorizations gains no columns.
    def join_resource_subtree(ds, resource_id_column)
      ds.
        join(resource_subtrees.as(:resource_descendants), ancestor_id: resource_id_column).
        join(Sequel[:super_auth_resources], id: Sequel[:resource_descendants][:descendant_id]).
        # A (type, NULL) row — a type-level node, every record of its type —
        # is only ever the node the grant named, never one reached through
        # the tree; the walk itself refuses the other direction, a node
        # reached through a type-level parent. Resource.assert_compilable!
        # refuses both shapes loudly, but it is a separate statement from this
        # one: under READ COMMITTED a write that nests a type-level node can
        # land between the two, and the compiled table must not widen a
        # container grant to a whole type, or a type-level grant to the nodes
        # under it, because of it.
        where(
          Sequel.|(
            { Sequel[:resource_descendants][:ancestor_id] => Sequel[:resource_descendants][:descendant_id] },
            { Sequel[:super_auth_resources][:external_type] => nil },
            Sequel.~(Sequel[:super_auth_resources][:external_id] => nil)
          )
        )
    end

    def users_groups_roles_permissions_resources
      cast_type = string_cast_type
      # Join users to their group via edges. group_ancestors pairs that group with itself and
      # every ancestor, so a group -> role edge on any of them applies. role_descendants then
      # expands the granted role to its whole subtree. Each step is correlated to the previous
      # one, so a role held by one group never reaches members of an unrelated group. The tree
      # CTEs (user_groups, granted_roles) are joined by id only to supply the path columns.
      ds = SuperAuth::User.db[:super_auth_users].
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        join(SuperAuth::Group.ancestor_pairs.as(:group_ancestors), descendant_id: Sequel[:user_edges][:group_id]).
        join(Sequel[:super_auth_edges].as(:group_role_edges), group_id: Sequel[:group_ancestors][:ancestor_id]).
        where(Sequel.~(Sequel[:group_role_edges][:role_id] => nil)).
        join(SuperAuth::Role.descendant_pairs.as(:role_descendants), ancestor_id: Sequel[:group_role_edges][:role_id]).
        join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:user_groups), Sequel[:user_groups][:id] => Sequel[:user_edges][:group_id]).
        join(SuperAuth::Role.from(SuperAuth::Role.trees).as(:granted_roles), Sequel[:granted_roles][:id] => Sequel[:role_descendants][:descendant_id]).
        join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:granted_roles][:id]).
        join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
        join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id])
      join_resource_subtree(ds, Sequel[:resource_edges][:resource_id]).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel[:user_groups][:id].as(:group_id),
          Sequel[:user_groups][:name].cast(cast_type).as(:group_name),
          Sequel[:user_groups][:group_path],
          Sequel[:user_groups][:group_name_path].cast(cast_type).as(:group_name_path),
          Sequel[:user_groups][:parent_id].as(:group_parent_id),
          Sequel[:user_groups][:created_at].cast(cast_type).as(:group_created_at),
          Sequel[:user_groups][:updated_at].cast(cast_type).as(:group_updated_at),

          Sequel[:granted_roles][:id].as(:role_id),
          Sequel[:granted_roles][:name].cast(cast_type).as(:role_name),
          Sequel[:granted_roles][:role_path],
          Sequel[:granted_roles][:role_name_path].cast(cast_type).as(:role_name_path),
          Sequel[:granted_roles][:parent_id].as(:role_parent_id),
          Sequel[:granted_roles][:created_at].cast(cast_type).as(:role_created_at),
          Sequel[:granted_roles][:updated_at].cast(cast_type).as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].cast(cast_type).as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        ).
        distinct
    end

    def users_groups_permissions_resources
      cast_type = string_cast_type
      # Join users to their group via edges. group_ancestors pairs that group with itself and
      # every ancestor, so a group -> permission edge on any of them applies. user_groups (the
      # tree) is joined by id only to supply the path columns.
      ds = SuperAuth::User.db[:super_auth_users].
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        join(SuperAuth::Group.ancestor_pairs.as(:group_ancestors), descendant_id: Sequel[:user_edges][:group_id]).
        join(Sequel[:super_auth_edges].as(:group_edges), group_id: Sequel[:group_ancestors][:ancestor_id]).
        join(SuperAuth::Group.from(SuperAuth::Group.trees).as(:user_groups), Sequel[:user_groups][:id] => Sequel[:user_edges][:group_id]).
        join(Sequel[:super_auth_permissions], id: Sequel[:group_edges][:permission_id]).
        join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:permission_id] => Sequel[:super_auth_permissions][:id])
      join_resource_subtree(ds, Sequel[:permission_edges][:resource_id]).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel[:user_groups][:id].as(:group_id),
          Sequel[:user_groups][:name].cast(cast_type).as(:group_name),
          Sequel[:user_groups][:group_path],
          Sequel[:user_groups][:group_name_path].cast(cast_type).as(:group_name_path),
          Sequel[:user_groups][:parent_id].as(:group_parent_id),
          Sequel[:user_groups][:created_at].cast(cast_type).as(:group_created_at),
          Sequel[:user_groups][:updated_at].cast(cast_type).as(:group_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:role_id),
          Sequel.cast(nil, string_cast_type).as(:role_name),
          Sequel.cast(nil, string_cast_type).as(:role_path),
          Sequel.cast(nil, string_cast_type).as(:role_name_path),
          Sequel.cast(nil, integer_cast_type).as(:role_parent_id),
          Sequel.cast(nil, string_cast_type).as(:role_created_at),
          Sequel.cast(nil, string_cast_type).as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].cast(cast_type).as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type),
        ).
        distinct
    end

    def users_roles_permissions_resources
      cast_type = string_cast_type

      # Join users to the roles they hold directly. role_descendants expands each held role to
      # its whole subtree; granted_roles (the tree) is joined by id only to supply the path columns.
      ds = SuperAuth::User.db[:super_auth_users].
      join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
      where(Sequel.~(Sequel[:user_edges][:role_id] => nil)).
      join(SuperAuth::Role.descendant_pairs.as(:role_descendants), ancestor_id: Sequel[:user_edges][:role_id]).
      join(SuperAuth::Role.from(SuperAuth::Role.trees).as(:granted_roles), Sequel[:granted_roles][:id] => Sequel[:role_descendants][:descendant_id]).
      select(
        Sequel[:super_auth_users][:id].as(:user_id),
        Sequel[:super_auth_users][:name].as(:user_name),
        Sequel[:super_auth_users][:external_id].as(:user_external_id),
        Sequel[:super_auth_users][:external_type].as(:user_external_type),
        Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
        Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

        Sequel.cast(nil, integer_cast_type).as(:group_id),
        Sequel.cast(nil, string_cast_type).as(:group_name),
        Sequel.cast(nil, string_cast_type).as(:group_path),
        Sequel.cast(nil, string_cast_type).as(:group_name_path),
        Sequel.cast(nil, integer_cast_type).as(:group_parent_id),
        Sequel.cast(nil, string_cast_type).as(:group_created_at),
        Sequel.cast(nil, string_cast_type).as(:group_updated_at),

        Sequel[:granted_roles][:id].as(:role_id),
        Sequel[:granted_roles][:name].cast(cast_type).as(:role_name),
        Sequel[:granted_roles][:role_path],
        Sequel[:granted_roles][:role_name_path].cast(cast_type).as(:role_name_path),
        Sequel[:granted_roles][:parent_id].as(:role_parent_id),
        Sequel[:granted_roles][:created_at].cast(cast_type).as(:role_created_at),
        Sequel[:granted_roles][:updated_at].cast(cast_type).as(:role_updated_at),

        Sequel[:super_auth_permissions][:id].as(:permission_id),
        Sequel[:super_auth_permissions][:name].cast(cast_type).as(:permission_name),
        Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
        Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

        Sequel[:super_auth_resources][:id].as(:resource_id),
        Sequel[:super_auth_resources][:name].as(:resource_name),
        Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
        Sequel[:super_auth_resources][:external_type].as(:resource_external_type),
      ).
      # Join permission and resource edges on the expanded role
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:role_id] => Sequel[:granted_roles][:id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id])
      join_resource_subtree(ds, Sequel[:resource_edges][:resource_id]).distinct
    end

    def users_permissions_resources
      cast_type = string_cast_type
      ds = SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:group_id),
          Sequel.cast(nil, string_cast_type).as(:group_name),
          Sequel.cast(nil, string_cast_type).as(:group_path),
          Sequel.cast(nil, string_cast_type).as(:group_name_path),
          Sequel.cast(nil, integer_cast_type).as(:group_parent_id),
          Sequel.cast(nil, string_cast_type).as(:group_created_at),
          Sequel.cast(nil, string_cast_type).as(:group_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:role_id),
          Sequel.cast(nil, string_cast_type).as(:role_name),
          Sequel.cast(nil, string_cast_type).as(:role_path),
          Sequel.cast(nil, string_cast_type).as(:role_name_path),
          Sequel.cast(nil, integer_cast_type).as(:role_parent_id),
          Sequel.cast(nil, string_cast_type).as(:role_created_at),
          Sequel.cast(nil, string_cast_type).as(:role_updated_at),

          Sequel[:super_auth_permissions][:id].as(:permission_id),
          Sequel[:super_auth_permissions][:name].cast(cast_type).as(:permission_name),
          Sequel[:super_auth_permissions][:created_at].cast(cast_type).as(:permission_created_at),
          Sequel[:super_auth_permissions][:updated_at].cast(cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        ).
      join(Sequel[:super_auth_edges].as(:permission_edges), Sequel[:permission_edges][:user_id] => Sequel[:super_auth_users][:id]).
      join(Sequel[:super_auth_permissions], id: Sequel[:permission_edges][:permission_id]).
      join(Sequel[:super_auth_edges].as(:resource_edges), Sequel[:resource_edges][:permission_id] => Sequel[:super_auth_permissions][:id])
      join_resource_subtree(ds, Sequel[:resource_edges][:resource_id]).distinct
    end

    def users_resources
      cast_type = string_cast_type
      ds = SuperAuth::User.
        join(Sequel[:super_auth_edges].as(:user_edges), user_id: :id).
        select(
          Sequel[:super_auth_users][:id].as(:user_id),
          Sequel[:super_auth_users][:name].as(:user_name),
          Sequel[:super_auth_users][:external_id].as(:user_external_id),
          Sequel[:super_auth_users][:external_type].as(:user_external_type),
          Sequel[:super_auth_users][:created_at].cast(cast_type).as(:user_created_at),
          Sequel[:super_auth_users][:updated_at].cast(cast_type).as(:user_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:group_id),
          Sequel.cast(nil, string_cast_type).as(:group_name),
          Sequel.cast(nil, string_cast_type).as(:group_path),
          Sequel.cast(nil, string_cast_type).as(:group_name_path),
          Sequel.cast(nil, integer_cast_type).as(:group_parent_id),
          Sequel.cast(nil, string_cast_type).as(:group_created_at),
          Sequel.cast(nil, string_cast_type).as(:group_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:role_id),
          Sequel.cast(nil, string_cast_type).as(:role_name),
          Sequel.cast(nil, string_cast_type).as(:role_path),
          Sequel.cast(nil, string_cast_type).as(:role_name_path),
          Sequel.cast(nil, integer_cast_type).as(:role_parent_id),
          Sequel.cast(nil, string_cast_type).as(:role_created_at),
          Sequel.cast(nil, string_cast_type).as(:role_updated_at),

          Sequel.cast(nil, integer_cast_type).as(:permission_id),
          Sequel.cast(nil, string_cast_type).as(:permission_name),
          Sequel.cast(nil, string_cast_type).as(:permission_created_at),
          Sequel.cast(nil, string_cast_type).as(:permission_updated_at),

          Sequel[:super_auth_resources][:id].as(:resource_id),
          Sequel[:super_auth_resources][:name].as(:resource_name),
          Sequel[:super_auth_resources][:external_id].as(:resource_external_id),
          Sequel[:super_auth_resources][:external_type].as(:resource_external_type)
        )
      join_resource_subtree(ds, Sequel[:user_edges][:resource_id]).distinct
    end
  end

  def to_h
    {
      user: self&.user&.name,
      group: self&.group&.name,
      role: self&.role&.name,
      resource: self&.resource&.name,
      permission: self&.permission&.name,
    }
  end
end
