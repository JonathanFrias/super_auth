require "spec_helper"
require "active_record"

# belongs_to :external resolves its class by name, so the stand-in for a
# host's model needs a real constant and a real table (as in label_spec).
class SuperAuthNestedSpecPost < ActiveRecord::Base
  self.table_name = "super_auth_nested_spec_posts"
end

# Resources nest like groups and roles (0.8.0): a grant on a node reaches the
# node and every node under it, through each of the five path strategies. A
# node with neither external_type nor external_id is a container. A node with
# an external_type and no external_id is a type-level (wildcard) node: a
# supported grant on every record of its type, which stays flat — the walk
# never descends from one and never reaches one through a parent.
RSpec.describe "nested resources" do
  let(:db) { SuperAuth.db }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_authorizations].delete
    db[:super_auth_edges].delete
    # MySQL checks the self-referencing parent_id key row by row, so detach
    # children before deleting the tree tables.
    db[:super_auth_groups].update(parent_id: nil)
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].update(parent_id: nil)
    db[:super_auth_roles].delete
    db[:super_auth_resources].update(parent_id: nil)
    db[:super_auth_resources].delete
  end

  let(:user) { SuperAuth::User.create(name: "u") }

  def compiled
    db[:super_auth_authorizations].select_map([:user_id, :group_id, :role_id, :permission_id, :resource_id])
  end

  def compiled_resource_ids(user)
    db[:super_auth_authorizations].where(user_id: user.id).select_map(:resource_id).uniq
  end

  # [resource_id, resource_external_type, resource_external_id] per compiled
  # row. The external id column has whatever type SuperAuth.external_id_type
  # chose at install, so it is compared as text.
  def compiled_resources
    db[:super_auth_authorizations].select_map([:resource_id, :resource_external_type, :resource_external_id]).
      map { |id, type, external_id| [id, type, external_id&.to_s] }
  end

  # A cycle that got in around the models. On Postgres migration 13's trigger
  # refuses the raw write too, so the statement runs with triggers off, as a
  # pg_restore or a replication apply does (session_replication_role): a
  # cycle that predates the migration, or arrived that way, is exactly what
  # the guards under test must still catch.
  def close_cycle(table, id, parent_id)
    guarded = table == :super_auth_resources && db.database_type == :postgres
    db.transaction do
      db.run "SET LOCAL session_replication_role = replica" if guarded
      db[table].where(id: id).update(parent_id: parent_id)
      db.run "SET LOCAL session_replication_role = origin" if guarded
    end
  end

  # A container holding two registered records. The records carry a type and
  # an id so the compiled rows show a descendant keeping its own columns; the
  # container carries neither.
  def container_with_records
    container = SuperAuth::Resource.create(name: "folder")
    a = SuperAuth::Resource.create(name: "a", external_type: "Document", external_id: "1", parent: container)
    b = SuperAuth::Resource.create(name: "b", external_type: "Document", external_id: "2", parent: container)
    [container, a, b]
  end

  describe "a grant on a container" do
    # One example per strategy, each asserting the strategy's own relation as
    # well as the compiled table, so a wrong join in one strategy cannot hide
    # behind the union.
    def expect_subtree(strategy, container, a, b)
      expect(SuperAuth::Authorization.compile!).to eq 3
      expect(compiled_resource_ids(user)).to match_array [container.id, a.id, b.id]
      expect(strategy.map { |row| row[:resource_id] }).to match_array [container.id, a.id, b.id]
    end

    it "reaches every node under it through user -> resource" do
      container, a, b = container_with_records
      SuperAuth::Edge.create(user: user, resource: container)

      expect_subtree(SuperAuth::Edge.users_resources, container, a, b)
    end

    it "reaches every node under it through user -> permission -> resource" do
      container, a, b = container_with_records
      permission = SuperAuth::Permission.create(name: "read")
      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: container)

      expect_subtree(SuperAuth::Edge.users_permissions_resources, container, a, b)
    end

    it "reaches every node under it through user -> role -> permission -> resource" do
      container, a, b = container_with_records
      role = SuperAuth::Role.create(name: "editor")
      permission = SuperAuth::Permission.create(name: "read")
      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: container)

      expect_subtree(SuperAuth::Edge.users_roles_permissions_resources, container, a, b)
    end

    it "reaches every node under it through user -> group -> permission -> resource" do
      container, a, b = container_with_records
      group = SuperAuth::Group.create(name: "staff")
      permission = SuperAuth::Permission.create(name: "read")
      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: container)

      expect_subtree(SuperAuth::Edge.users_groups_permissions_resources, container, a, b)
    end

    it "reaches every node under it through user -> group -> role -> permission -> resource" do
      container, a, b = container_with_records
      group = SuperAuth::Group.create(name: "staff")
      role = SuperAuth::Role.create(name: "editor")
      permission = SuperAuth::Permission.create(name: "read")
      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: container)

      expect_subtree(SuperAuth::Edge.users_groups_roles_permissions_resources, container, a, b)
    end

    it "reaches three levels down, and from the middle only what is under it" do
      root = SuperAuth::Resource.create(name: "root")
      mid = SuperAuth::Resource.create(name: "mid", parent: root)
      leaf = SuperAuth::Resource.create(name: "leaf", parent: mid)
      from_the_middle = SuperAuth::User.create(name: "from the middle")
      SuperAuth::Edge.create(user: user, resource: root)
      SuperAuth::Edge.create(user: from_the_middle, resource: mid)

      expect(SuperAuth::Authorization.compile!).to eq 5
      expect(compiled_resource_ids(user)).to match_array [root.id, mid.id, leaf.id]
      expect(compiled_resource_ids(from_the_middle)).to match_array [mid.id, leaf.id]
    end

    # Each compiled row copies the descendant's own columns: containment is
    # not inheritance. The container's row has no external_type, and both
    # ByCurrentUser branches and the RLS policy key on that column, so the row
    # names no record at runtime (spec/active_record/by_current_user_spec.rb
    # and spec/rls_spec.rb pin that end to end).
    it "compiles each descendant with its own type and id, and the container with neither" do
      container, a, b = container_with_records
      SuperAuth::Edge.create(user: user, resource: container)
      SuperAuth::Authorization.compile!

      expect(compiled_resources).to match_array [[container.id, nil, nil], [a.id, "Document", "1"], [b.id, "Document", "2"]]
      # The shape the type-level branch reads, (type, NULL id), is not there.
      expect(db[:super_auth_authorizations].where(resource_external_id: nil).exclude(resource_external_type: nil).count).to eq 0
    end
  end

  describe "a grant on a child" do
    it "reaches neither its parent nor its sibling" do
      _container, a, _b = container_with_records
      SuperAuth::Edge.create(user: user, resource: a)

      expect(SuperAuth::Authorization.compile!).to eq 1
      expect(compiled_resource_ids(user)).to eq [a.id]
    end
  end

  describe "the subtree walk" do
    # Anchored on the ids that appear in edges: a node nobody granted is not
    # walked, however many descendants it has.
    it "walks only the subtrees a grant names" do
      granted = SuperAuth::Resource.create(name: "granted")
      g1 = SuperAuth::Resource.create(name: "g1", parent: granted)
      g2 = SuperAuth::Resource.create(name: "g2", parent: granted)
      other = SuperAuth::Resource.create(name: "other")
      SuperAuth::Resource.create(name: "o1", parent: other)
      SuperAuth::Edge.create(user: user, resource: granted)

      pairs = SuperAuth::Edge.resource_subtrees.map { |r| [r[:ancestor_id], r[:descendant_id]] }
      expect(pairs).to match_array [[granted.id, granted.id], [granted.id, g1.id], [granted.id, g2.id]]
      expect(SuperAuth::Authorization.compile!).to eq 3
      expect(compiled_resource_ids(user)).to match_array [granted.id, g1.id, g2.id]
    end

    it "restricts descendant_pairs to the nodes named by of:" do
      root = SuperAuth::Resource.create(name: "root")
      child = SuperAuth::Resource.create(name: "child", parent: root)
      grandchild = SuperAuth::Resource.create(name: "grandchild", parent: child)

      pairs = SuperAuth::Resource.descendant_pairs(of: [child.id]).map { |r| [r[:ancestor_id], r[:descendant_id]] }
      expect(pairs).to match_array [[child.id, child.id], [child.id, grandchild.id]]
      expect(SuperAuth::Resource.descendant_pairs.count).to eq 6
    end
  end

  describe "on a flat graph" do
    # The subtree relation is the identity there, so the compiled rows are
    # exactly what the previous pk join produced. No resource path columns,
    # unlike groups and roles: super_auth_authorizations gains nothing.
    it "compiles the same 28 columns as before" do
      expect(SuperAuth::Edge.authorizations.columns).to eq %i[
        user_id user_name user_external_id user_external_type user_created_at user_updated_at
        group_id group_name group_path group_name_path group_parent_id group_created_at group_updated_at
        role_id role_name role_path role_name_path role_parent_id role_created_at role_updated_at
        permission_id permission_name permission_created_at permission_updated_at
        resource_id resource_name resource_external_id resource_external_type
      ]
    end

    it "compiles one row per strategy, each naming the node the grant named" do
      g1 = SuperAuth::Group.create(name: "g1")
      g3 = SuperAuth::Group.create(name: "g3")
      r1 = SuperAuth::Role.create(name: "r1")
      r2 = SuperAuth::Role.create(name: "r2")
      p1, p2, p3, p4 = %w[p1 p2 p3 p4].map { |name| SuperAuth::Permission.create(name: name) }
      res1 = SuperAuth::Resource.create(name: "res1", external_type: "Document", external_id: "1")
      res2, res3, res4, res5 = %w[res2 res3 res4 res5].map { |name| SuperAuth::Resource.create(name: name) }

      SuperAuth::Edge.create(user: user, group: g1)      # 1: user -> group -> role -> permission -> resource
      SuperAuth::Edge.create(group: g1, role: r1)
      SuperAuth::Edge.create(role: r1, permission: p1)
      SuperAuth::Edge.create(permission: p1, resource: res1)
      SuperAuth::Edge.create(user: user, role: r2)       # 2: user -> role -> permission -> resource
      SuperAuth::Edge.create(role: r2, permission: p2)
      SuperAuth::Edge.create(permission: p2, resource: res2)
      SuperAuth::Edge.create(user: user, group: g3)      # 3: user -> group -> permission -> resource
      SuperAuth::Edge.create(group: g3, permission: p3)
      SuperAuth::Edge.create(permission: p3, resource: res3)
      SuperAuth::Edge.create(user: user, permission: p4) # 4: user -> permission -> resource
      SuperAuth::Edge.create(permission: p4, resource: res4)
      SuperAuth::Edge.create(user: user, resource: res5) # 5: user -> resource

      expect(SuperAuth::Authorization.compile!).to eq 5
      expect(compiled).to match_array [
        [user.id, g1.id, r1.id, p1.id, res1.id],
        [user.id, nil, r2.id, p2.id, res2.id],
        [user.id, g3.id, nil, p3.id, res3.id],
        [user.id, nil, nil, p4.id, res4.id],
        [user.id, nil, nil, nil, res5.id],
      ]
      expect(compiled_resources).to include [res1.id, "Document", "1"]
    end
  end

  describe "wildcard nodes are flat" do
    # A wildcard nested in the tree would compile to a (type, NULL) row that
    # every ancestor's grants reach: one edge to a container silently granting
    # every record of a type. Both twins refuse before the delete, so the
    # previous rows stay.
    def compile_three_rows
      container, _a, _b = container_with_records
      SuperAuth::Edge.create(user: user, resource: container)
      expect(SuperAuth::Authorization.compile!).to eq 3
      container
    end

    def expect_both_twins_to_refuse(*ids)
      listed = ids.sort.join(", ")
      expect { SuperAuth::Authorization.compile! }.
        to raise_error(SuperAuth::Error, /wildcard node\(s\) #{listed} have a parent or children/)
      expect { SuperAuth::ActiveRecord::Authorization.compile! }.
        to raise_error(SuperAuth::Error, /wildcard node\(s\) #{listed} have a parent or children/)
      expect(db[:super_auth_authorizations].count).to eq 3
    end

    it "refuses to compile a wildcard node that was given a parent, and keeps the compiled rows" do
      container = compile_three_rows
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      db[:super_auth_resources].where(id: wildcard.id).update(parent_id: container.id)

      expect_both_twins_to_refuse(wildcard.id)
    end

    it "refuses to compile a wildcard node that has a child, and keeps the compiled rows" do
      compile_three_rows
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      child = SuperAuth::Resource.create(name: "child")
      db[:super_auth_resources].where(id: child.id).update(parent_id: wildcard.id)

      expect_both_twins_to_refuse(wildcard.id)
    end

    it "names every offending node, in id order" do
      container = compile_three_rows
      first = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      second = SuperAuth::Resource.create(name: "all claims", external_type: "Claim")
      db[:super_auth_resources].where(id: [first.id, second.id]).update(parent_id: container.id)

      expect_both_twins_to_refuse(first.id, second.id)
    end

    it "compiles a flat wildcard to the (type, NULL) row it always did" do
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      SuperAuth::Edge.create(user: user, resource: wildcard)

      expect(SuperAuth::Authorization.compile!).to eq 1
      expect(compiled_resources).to eq [[wildcard.id, "Document", nil]]
    end

    # The guard and the compile are two statements; under READ COMMITTED a
    # write can land between them. The join is the guarantee, so it is
    # exercised here with the guard bypassed.
    it "never copies a wildcard reached through the tree, even past the guard" do
      container, _a, _b = container_with_records
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      db[:super_auth_resources].where(id: wildcard.id).update(parent_id: container.id)
      SuperAuth::Edge.create(user: user, resource: container)

      rows = SuperAuth::Edge.authorizations.map { |r| [r[:resource_external_type], r[:resource_external_id]&.to_s] }
      expect(rows).to include(["Document", "1"], ["Document", "2"])
      expect(rows).not_to include(["Document", nil])
    end

    # The other direction. A per-record node nested under a wildcard used to
    # receive the wildcard's grants through the walk: one accidental
    # parent_id, and "every Claim" also compiled a row per claim node under
    # it — a row for every claim in a real graph. The walk itself no longer
    # descends from a wildcard, so this holds for a host that reads
    # Edge.authorizations directly and never runs the guard.
    it "never descends from a wildcard, even past the guard: a wildcard grant is its own row only" do
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      one = SuperAuth::Resource.create(name: "one", external_type: "Document", external_id: "1")
      two = SuperAuth::Resource.create(name: "two", external_type: "Document", external_id: "2", parent: one)
      db[:super_auth_resources].where(id: one.id).update(parent_id: wildcard.id)
      permission = SuperAuth::Permission.create(name: "read")
      SuperAuth::Edge.create(user: user, resource: wildcard)
      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: wildcard)

      pairs = SuperAuth::Edge.resource_subtrees.map { |r| [r[:ancestor_id], r[:descendant_id]] }
      expect(pairs).to eq [[wildcard.id, wildcard.id]]
      # Two strategies each yield the wildcard's own row, and nothing else.
      [SuperAuth::Edge.authorizations, SuperAuth::Edge.users_resources, SuperAuth::Edge.users_permissions_resources].each do |relation|
        rows = relation.map { |r| [r[:resource_id], r[:resource_external_type], r[:resource_external_id]&.to_s] }
        expect(rows.uniq).to eq [[wildcard.id, "Document", nil]]
      end
      expect(SuperAuth::Edge.authorizations.count).to eq 2
      expect(SuperAuth::Resource.descendant_pairs(of: [wildcard.id]).count).to eq 1
      expect(SuperAuth::Resource.descendant_pairs(of: [one.id]).map { |r| r[:descendant_id] }).to match_array [one.id, two.id]
    end

    it "stops at a wildcard in the middle of a tree: neither it nor anything under it is reached" do
      container, a, _b = container_with_records
      wildcard = SuperAuth::Resource.create(name: "all claims", external_type: "Claim")
      under = SuperAuth::Resource.create(name: "claim 9", external_type: "Claim", external_id: "9")
      db[:super_auth_resources].where(id: wildcard.id).update(parent_id: container.id)
      db[:super_auth_resources].where(id: under.id).update(parent_id: wildcard.id)
      SuperAuth::Edge.create(user: user, resource: container)

      ids = SuperAuth::Edge.authorizations.map { |r| r[:resource_id] }
      expect(ids).to include(container.id, a.id)
      expect(ids).not_to include(wildcard.id, under.id)
    end
  end

  describe "SuperAuth::Resource.record" do
    it "finds the node registered for one record, by type name or class" do
      node = SuperAuth::Resource.create(name: "doc 1", external_type: "Document", external_id: "1")
      SuperAuth::Resource.create(name: "all docs", external_type: "Document")

      expect(SuperAuth::Resource.record("Document", "1")).to eq node
      expect(SuperAuth::Resource.record(SuperAuthNestedSpecPost, "1")).to be_nil
      expect(SuperAuth::Resource.record("Document", "2")).to be_nil
    end

    # where(external_type: type, external_id: nil) is the wildcard, not "no
    # node": a host helper handed an unset foreign key would otherwise grant,
    # revoke or delete the node that covers every record of the type.
    it "refuses a nil id instead of answering with the type-level node" do
      SuperAuth::Resource.create(name: "all docs", external_type: "Document")

      expect { SuperAuth::Resource.record("Document", nil) }.
        to raise_error(SuperAuth::Error, /record\("Document", nil\): the id is nil.*type-level node for every Document record/)
    end
  end

  describe "cycles" do
    # A cycle does not hang a compile (UNION), which is exactly the problem:
    # every node in it is an ancestor of every other, so a grant on any of
    # them silently reaches all their subtrees. Refused at the model, in
    # both ORMs, and by compile! for a write that went around them.
    describe "at the model" do
      it "refuses a resource that is made its own parent" do
        node = SuperAuth::Resource.create(name: "loop")

        expect { node.update(parent_id: node.id) }.to raise_error(Sequel::ValidationFailed, /parent_id cannot be the node itself/)
        expect(SuperAuth::Resource[node.id].parent_id).to be_nil
      end

      it "refuses a parent inside the node's own subtree, and allows any other" do
        a = SuperAuth::Resource.create(name: "a")
        b = SuperAuth::Resource.create(name: "b", parent: a)
        c = SuperAuth::Resource.create(name: "c", parent: b)
        elsewhere = SuperAuth::Resource.create(name: "elsewhere")

        expect { a.update(parent: c) }.to raise_error(Sequel::ValidationFailed, /parent_id is inside the node's own subtree, which would close a cycle/)
        expect { a.update(parent_id: b.id) }.to raise_error(Sequel::ValidationFailed)
        expect(SuperAuth::Resource[a.id].parent_id).to be_nil
        a.update(parent: elsewhere)
        expect(SuperAuth::Resource[a.id].parent_id).to eq elsewhere.id
        c.update(parent: a)
        expect(SuperAuth::Resource[c.id].parent_id).to eq a.id
      end

      # The check walks up from the new parent, so it does not stop where the
      # descendant walk stops: a wildcard that was given children (raw) is
      # still refused as a parent of one of them.
      it "catches a cycle through a wildcard, where the descendant walk would not look" do
        wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
        child = SuperAuth::Resource.create(name: "child")
        db[:super_auth_resources].where(id: child.id).update(parent_id: wildcard.id)

        expect { wildcard.update(parent_id: child.id) }.to raise_error(Sequel::ValidationFailed, /inside the node's own subtree/)
      end

      it "does not run the walk for a save that leaves parent_id alone" do
        a = SuperAuth::Resource.create(name: "a")
        b = SuperAuth::Resource.create(name: "b", parent: a)
        close_cycle(:super_auth_resources, a.id, b.id) # already there

        expect { b.update(name: "renamed") }.not_to raise_error
      end

      %w[Group Role Resource].each do |name|
        it "(ActiveRecord) refuses both shapes on #{name}" do
          model = SuperAuth::ActiveRecord.const_get(name)
          a = model.create!(name: "a")
          b = model.create!(name: "b", parent: a)
          c = model.create!(name: "c", parent: b)

          expect { a.update!(parent_id: a.id) }.to raise_error(ActiveRecord::RecordInvalid, /Parent cannot be the node itself/)
          expect { a.update!(parent: c) }.to raise_error(ActiveRecord::RecordInvalid, /Parent is inside the node's own subtree, which would close a cycle/)
          expect(a.update(parent_id: b.id)).to be false
          expect(a.errors[:parent_id]).to eq ["is inside the node's own subtree, which would close a cycle"]
          expect(model.find(a.id).parent_id).to be_nil
          expect(c.update(parent: a)).to be true
        end
      end
    end

    describe "assert_acyclic!" do
      it "passes a forest and names every node no root reaches, on a raw cycle" do
        root = SuperAuth::Resource.create(name: "root")
        SuperAuth::Resource.create(name: "child", parent: root)
        expect { SuperAuth::Resource.assert_acyclic! }.not_to raise_error

        a = SuperAuth::Resource.create(name: "a")
        b = SuperAuth::Resource.create(name: "b", parent: a)
        hanging = SuperAuth::Resource.create(name: "hanging", parent: b)
        close_cycle(:super_auth_resources, a.id, b.id)

        expect { SuperAuth::Resource.assert_acyclic! }.to raise_error(
          SuperAuth::Error,
          "super_auth_resources has a parent_id cycle: node(s) #{[a.id, b.id, hanging.id].sort.join(', ')} cannot be reached from any root. " \
          "Point one of them at a root, or at no parent, and recompile."
        )
        expect { SuperAuth::Group.assert_acyclic! }.not_to raise_error
        expect { SuperAuth::Role.assert_acyclic! }.not_to raise_error
      end

      it "makes both compile! twins refuse a cycle in any tree table, before the delete" do
        container, _a, _b = container_with_records
        SuperAuth::Edge.create(user: user, resource: container)
        expect(SuperAuth::Authorization.compile!).to eq 3

        {
          SuperAuth::Group => :super_auth_groups, SuperAuth::Role => :super_auth_roles, SuperAuth::Resource => :super_auth_resources,
        }.each do |model, table|
          a = model.create(name: "a")
          b = model.create(name: "b", parent: a)
          close_cycle(table, a.id, b.id)

          expect { SuperAuth::Authorization.compile! }.to raise_error(SuperAuth::Error, /#{table} has a parent_id cycle: node\(s\) #{a.id}, #{b.id}/)
          expect { SuperAuth::ActiveRecord::Authorization.compile! }.to raise_error(SuperAuth::Error, /#{table} has a parent_id cycle/)
          expect(db[:super_auth_authorizations].count).to eq 3
          db[table].where(id: a.id).update(parent_id: nil)
        end
        expect(SuperAuth::Authorization.compile!).to eq 3
      end
    end
  end

  describe "destroying a node" do
    # A node's compiled rows and edges go with it, in the same transaction;
    # everything else compiled waits for the next compile, like any other
    # revocation. Children are not touched.
    def compile_container_graph
      container, a, b = container_with_records
      other = SuperAuth::User.create(name: "other")
      SuperAuth::Edge.create(user: user, resource: container)
      SuperAuth::Edge.create(user: other, resource: a)
      expect(SuperAuth::Authorization.compile!).to eq 4
      [container, a, b, other]
    end

    it "purges the resource's compiled rows and edges" do
      _container, a, b, other = compile_container_graph

      a.destroy
      expect(db[:super_auth_resources].select_map(:id)).not_to include(a.id)
      expect(db[:super_auth_edges].where(resource_id: a.id).count).to eq 0
      expect(db[:super_auth_authorizations].where(resource_id: a.id).count).to eq 0
      expect(db[:super_auth_authorizations].count).to eq 2
      expect(db[:super_auth_edges].count).to eq 1
      expect(SuperAuth::Resource[b.id]).not_to be_nil
      expect(SuperAuth::User[other.id]).not_to be_nil
    end

    it "purges a group's and a role's compiled rows and edges" do
      group = SuperAuth::Group.create(name: "staff")
      role = SuperAuth::Role.create(name: "editor")
      permission = SuperAuth::Permission.create(name: "read")
      res = SuperAuth::Resource.create(name: "doc")
      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: res)
      direct = SuperAuth::Edge.create(user: user, resource: res)
      expect(SuperAuth::Authorization.compile!).to eq 3

      group.destroy
      expect(db[:super_auth_authorizations].where(group_id: group.id).count).to eq 0
      expect(db[:super_auth_authorizations].count).to eq 2
      expect(db[:super_auth_edges].where(group_id: group.id).count).to eq 0

      role.destroy
      expect(db[:super_auth_authorizations].where(role_id: role.id).count).to eq 0
      expect(db[:super_auth_authorizations].select_map(:resource_id)).to eq [res.id]
      expect(db[:super_auth_edges].select_map(:id)).to match_array [direct.id, db[:super_auth_edges].first(permission_id: permission.id, resource_id: res.id)[:id]]
    end

    it "(ActiveRecord) purges the same way from each twin" do
      _container, a, _b, _other = compile_container_graph
      group = SuperAuth::ActiveRecord::Group.create!(name: "staff")
      role = SuperAuth::ActiveRecord::Role.create!(name: "editor")
      permission = SuperAuth::ActiveRecord::Permission.create!(name: "read")
      SuperAuth::ActiveRecord::Edge.create!(user_id: user.id, group_id: group.id)
      SuperAuth::ActiveRecord::Edge.create!(user_id: user.id, role_id: role.id)
      SuperAuth::ActiveRecord::Edge.create!(group_id: group.id, permission_id: permission.id)
      SuperAuth::ActiveRecord::Edge.create!(role_id: role.id, permission_id: permission.id)
      SuperAuth::ActiveRecord::Edge.create!(permission_id: permission.id, resource_id: a.id)
      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq 6

      SuperAuth::ActiveRecord::Resource.find(a.id).destroy!
      expect(db[:super_auth_authorizations].where(resource_id: a.id).count).to eq 0
      expect(db[:super_auth_edges].where(resource_id: a.id).count).to eq 0
      expect(db[:super_auth_authorizations].count).to eq 2

      SuperAuth::ActiveRecord::Group.find(group.id).destroy!
      SuperAuth::ActiveRecord::Role.find(role.id).destroy!
      expect(db[:super_auth_edges].where(group_id: group.id).or(role_id: role.id).count).to eq 0
      expect(db[:super_auth_edges].count).to eq 1
      expect(db[:super_auth_authorizations].count).to eq 2
    end
  end

  describe "migrations" do
    let(:sequel_migrations) { File.expand_path("../db/migrate", __dir__) }
    let(:ar_migrations) { File.expand_path("../db/migrate_activerecord", __dir__) }

    def mysql?
      %i[mysql mysql2].include?(db.database_type)
    end

    # reload: the ActiveRecord migrator changes tables behind Sequel's schema
    # cache.
    def resource_columns
      db.schema(:super_auth_resources, reload: true).map(&:first)
    end

    def parent_foreign_keys
      db.foreign_key_list(:super_auth_resources).select { |fk| fk[:columns] == [:parent_id] }.map { |fk| fk[:table] }
    end

    # Referencing tables first, so foreign keys never block a drop; both
    # migrators' bookkeeping tables too.
    def drop_everything
      %i[super_auth_authorizations super_auth_edges super_auth_groups super_auth_roles
         super_auth_users super_auth_permissions super_auth_resources
         schema_info schema_migrations ar_internal_metadata].each { |table| db.drop_table?(table) }
    end

    def postgres?
      db.database_type == :postgres
    end

    # Sequel's `indexes` reports neither an expression index nor an invalid
    # one, so the catalogue answers this.
    def index_exists?(name)
      !db.fetch("SELECT to_regclass(?) AS oid", name.to_s).first[:oid].nil?
    end

    # Migration 12's shapes are measured, not incidental: idx_sa_auth_by_resource
    # leads on the id because a host's per-record work slices by record across
    # several node types, and the two expression indexes exist because the
    # policy compares a cast column, which no plain btree serves. Nothing else
    # in the suite notices a flipped column order or a lost index.
    it "builds migration 12's indexes with the shapes the workloads need" do
      SuperAuth.uninstall_migrations
      SuperAuth.install_migrations

      expect(db.indexes(:super_auth_authorizations)[:idx_sa_auth_by_resource][:columns])
        .to eq %i[resource_external_id resource_external_type]
      expect(db.indexes(:super_auth_resources)[:idx_sa_resources_by_external][:columns])
        .to eq %i[external_type external_id]
      next unless postgres?

      # Both identity halves are emitted whatever identity a host asserts, so
      # the user_id index is unconditional. The external one is gated on the
      # column's catalogue type: this suite installs the default :string, where
      # varchar->text is a no-op cast that migration 9's plain btree already
      # answers as a seek, so the gate skips a duplicate.
      expect(index_exists?(:idx_sa_auth_by_internal_user_text)).to be true
      external_is_text = %w[varchar text].include?(
        db.fetch(<<~SQL).first[:typname],
          SELECT t.typname FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
          WHERE a.attrelid = to_regclass('super_auth_authorizations') AND a.attname = 'user_external_id'
        SQL
      )
      expect(index_exists?(:idx_sa_auth_by_current_user_text)).to be(!external_is_text)
    ensure
      SuperAuth.install_migrations
      SuperAuth.refresh_model_schemas
    end

    # A host that built its own index under one of these names keeps it: up
    # skips the name, and down drops nothing, so neither direction can take it.
    it "leaves an index a host already created under one of migration 12's names" do
      SuperAuth.uninstall_migrations
      Sequel::Migrator.run(db, sequel_migrations, target: 11)
      db.add_index :super_auth_authorizations, [:resource_external_type], name: :idx_sa_auth_by_resource
      SuperAuth.install_migrations

      expect(db.indexes(:super_auth_authorizations)[:idx_sa_auth_by_resource][:columns]).to eq %i[resource_external_type]

      Sequel::Migrator.run(db, sequel_migrations, target: 11)
      expect(db.indexes(:super_auth_authorizations)[:idx_sa_auth_by_resource][:columns]).to eq %i[resource_external_type]
    ensure
      SuperAuth.uninstall_migrations
      SuperAuth.install_migrations
      SuperAuth.refresh_model_schemas
    end

    it "adds parent_id with a foreign key on the way up and removes it on the way down" do
      SuperAuth.uninstall_migrations
      expect(db.table_exists?(:super_auth_resources)).to be false

      SuperAuth.install_migrations
      expect(resource_columns).to include(:parent_id)
      expect(parent_foreign_keys).to eq [:super_auth_resources]
      expect(SuperAuth::Resource.columns).to include(:parent_id)

      Sequel::Migrator.run(db, sequel_migrations, target: 10)
      expect(resource_columns).not_to include(:parent_id)
      expect(parent_foreign_keys).to be_empty
    ensure
      SuperAuth.install_migrations
      SuperAuth.refresh_model_schemas
    end

    it "(ActiveRecord) adds parent_id with a foreign key on the way up and removes it on the way down" do
      # Pre-existing and unrelated to 11: 20250101000001's timestamps default
      # is invalid for a datetime(6) on MySQL 8, so the chain cannot start.
      skip "the ActiveRecord migration chain does not run on MySQL" if mysql?
      verbose = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      begin
        SuperAuth.uninstall_migrations
      rescue SuperAuth::Error
      end
      drop_everything

      ActiveRecord::MigrationContext.new(ar_migrations).migrate
      expect(resource_columns).to include(:parent_id)
      expect(parent_foreign_keys).to eq [:super_auth_resources]
      # The twin builds migration 12's indexes the same way round; drift
      # between the flavours is otherwise invisible.
      expect(db.indexes(:super_auth_authorizations)[:idx_sa_auth_by_resource][:columns])
        .to eq %i[resource_external_id resource_external_type]
      expect(db.indexes(:super_auth_resources)[:idx_sa_resources_by_external][:columns])
        .to eq %i[external_type external_id]
      expect(index_exists?(:idx_sa_auth_by_internal_user_text)).to be true if postgres?

      ActiveRecord::MigrationContext.new(ar_migrations).migrate(0)
      expect(db.table_exists?(:super_auth_resources)).to be false
    ensure
      ActiveRecord::Migration.verbose = verbose unless verbose.nil?
      drop_everything
      SuperAuth.install_migrations
      SuperAuth.refresh_model_schemas
    end
  end

  describe "SuperAuth::ActiveRecord::Resource" do
    before do
      db.create_table?(:super_auth_nested_spec_posts) do
        primary_key :id
        String :title
      end
      db[:super_auth_nested_spec_posts].delete
      SuperAuthNestedSpecPost.reset_column_information
    end

    after do
      db.drop_table?(:super_auth_nested_spec_posts)
    end

    it "nests a record's node under a container, and derives a label only for the record" do
      container = SuperAuth::ActiveRecord::Resource.create!(name: "posts")
      post = SuperAuthNestedSpecPost.create!(title: "Hello")
      node = SuperAuth::ActiveRecord::Resource.create!(external: post, parent: container)

      expect(node.reload.parent).to eq container
      expect(node.parent_id).to eq container.id
      expect(container.reload.parent).to be_nil
      expect(node.super_auth_label).to eq "Hello"

      container.refresh_label!
      expect(container.reload.super_auth_label).to be_nil
    end

    it "compiles a grant on the container down to the record's node" do
      container = SuperAuth::ActiveRecord::Resource.create!(name: "posts")
      post = SuperAuthNestedSpecPost.create!(title: "Hello")
      node = SuperAuth::ActiveRecord::Resource.create!(external: post, parent: container)
      member = SuperAuth::ActiveRecord::User.create!(name: "member")
      SuperAuth::ActiveRecord::Edge.create!(user: member, resource: container)

      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq 2
      expect(compiled_resources).to match_array [[container.id, nil, nil], [node.id, "SuperAuthNestedSpecPost", post.id.to_s]]
    end
  end
end
