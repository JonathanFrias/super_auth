require "spec_helper"

# Findings from the September 2026 test audit, pinned as specs. Nothing here is
# fixed yet.
#
# - An example that starts with `pending "..."` documents a live defect: it runs,
#   fails, and RSpec reports it as pending. When a fix lands the example passes,
#   RSpec then fails it with "Expected pending ... to fail", and the `pending`
#   line should be deleted.
# - An example without `pending` is a tripwire for behaviour that is correct
#   today and must stay that way.
#
# Full context for every finding (A1, A2, ... match the tags in the titles):
# ~/.claude/plans/superauth-audit-fix-handoff.md
RSpec.describe "Audit: graph invariants and tree semantics" do
  let(:db) { SuperAuth.db }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_edges].delete
    db[:super_auth_groups].update(parent_id: nil)
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].update(parent_id: nil)
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  def mysql?
    %i[mysql mysql2].include?(db.database_type)
  end

  # Bound a query that may never return (A1). Postgres and MySQL have statement
  # timeouts; SQLite is interrupted from a timer thread, because a runaway
  # recursive CTE is a single C call that Ruby's Timeout cannot preempt.
  def with_query_timeout(seconds)
    timer = nil
    case db.database_type
    when :postgres then db.run "SET statement_timeout = #{(seconds * 1000).to_i}"
    when :mysql, :mysql2 then db.run "SET SESSION max_execution_time = #{(seconds * 1000).to_i}"
    else
      raw = db.synchronize { |conn| conn }
      timer = Thread.new { sleep seconds; raw.interrupt }
    end
    yield
  ensure
    timer&.kill
    case db.database_type
    when :postgres then db.run "SET statement_timeout = 0"
    when :mysql, :mysql2 then db.run "SET SESSION max_execution_time = 0"
    end
  end

  def grants
    SuperAuth::Edge.authorizations.all.map { |a| [a[:user_name], a[:group_name], a[:role_name], a[:permission_name], a[:resource_name]] }.sort_by(&:to_s)
  end

  describe "A1: cycles in the group and role trees" do
    it "A1: rejects a group that is made its own parent" do
      pending "A1: nothing prevents parent_id = id (no model validation, no CHECK constraint)"
      group = SuperAuth::Group.create(name: "loop")
      expect { group.update(parent_id: group.id) }.to raise_error(StandardError)
    end

    it "A1: rejects re-parenting that closes a two-node cycle" do
      pending "A1: nothing prevents a -> b -> a"
      a = SuperAuth::Group.create(name: "a")
      b = SuperAuth::Group.create(name: "b", parent: a)
      expect { a.update(parent_id: b.id) }.to raise_error(StandardError)
    end

    it "A1: rejects a role that is made its own parent" do
      pending "A1: nothing prevents parent_id = id (no model validation, no CHECK constraint)"
      role = SuperAuth::Role.create(name: "loop")
      expect { role.update(parent_id: role.id) }.to raise_error(StandardError)
    end

    it "A1: Group.ancestor_pairs terminates on a cyclic tree" do
      pending "A1: UNION ALL recursion never terminates, so compile! hangs (introduced with ancestor_pairs in 0.4.0)"
      a = SuperAuth::Group.create(name: "a")
      b = SuperAuth::Group.create(name: "b", parent: a)
      db[:super_auth_groups].where(id: a.id).update(parent_id: b.id) # raw, bypassing any future model validation

      pairs = with_query_timeout(3) { SuperAuth::Group.ancestor_pairs.map { |r| [r[:descendant_id], r[:ancestor_id]] } }
      expect(pairs).to include([a.id, a.id], [a.id, b.id], [b.id, a.id], [b.id, b.id])
    end

    it "A1: Role.descendant_pairs terminates on a cyclic tree" do
      pending "A1: UNION ALL recursion never terminates, so compile! hangs (introduced with descendant_pairs in 0.4.0)"
      a = SuperAuth::Role.create(name: "a")
      b = SuperAuth::Role.create(name: "b", parent: a)
      db[:super_auth_roles].where(id: a.id).update(parent_id: b.id)

      pairs = with_query_timeout(3) { SuperAuth::Role.descendant_pairs.map { |r| [r[:ancestor_id], r[:descendant_id]] } }
      expect(pairs).to include([a.id, a.id], [a.id, b.id], [b.id, a.id], [b.id, b.id])
    end
  end

  describe "A2: an edge must link exactly two nodes" do
    it "A2: rejects an edge with no ids" do
      pending "A2: no validation or CHECK constraint on edge shape; a row of NULLs is accepted"
      expect { SuperAuth::Edge.create({}) }.to raise_error(StandardError)
    end

    it "A2: rejects an edge with three ids" do
      pending "A2: no validation or CHECK constraint on edge shape"
      user = SuperAuth::User.create(name: "u")
      permission = SuperAuth::Permission.create(name: "p")
      resource = SuperAuth::Resource.create(name: "r")
      expect { SuperAuth::Edge.create(user: user, permission: permission, resource: resource) }.to raise_error(StandardError)
    end

    it "A2: (ActiveRecord) rejects an edge with three ids" do
      pending "A2: no validation or CHECK constraint on edge shape"
      user = SuperAuth::ActiveRecord::User.create!(name: "u")
      permission = SuperAuth::ActiveRecord::Permission.create!(name: "p")
      resource = SuperAuth::ActiveRecord::Resource.create!(name: "r")
      expect { SuperAuth::ActiveRecord::Edge.create!(user: user, permission: permission, resource: resource) }.to raise_error(StandardError)
    end

    it "A2: a three-id row inserted behind the model's back grants nothing" do
      pending "A2: strategies 4 and 5 read one row as user->permission, permission->resource and user->resource, so it self-grants"
      user = SuperAuth::User.create(name: "u")
      permission = SuperAuth::Permission.create(name: "p")
      resource = SuperAuth::Resource.create(name: "r")
      inserted = begin
        db[:super_auth_edges].insert(user_id: user.id, permission_id: permission.id, resource_id: resource.id)
        true
      rescue Sequel::DatabaseError
        false # a CHECK constraint rejected it, which is also a fix
      end

      expect(SuperAuth::Edge.authorizations.all).to be_empty if inserted
    end
  end

  describe "A3: descendants_dataset" do
    it "A3: a root's descendants exclude the other trees in the forest" do
      pending "A3: a root is anchored on parent_id IS NULL, which matches every root, so the whole forest comes back"
      r1 = SuperAuth::Group.create(name: "r1")
      c1 = SuperAuth::Group.create(name: "c1", parent: r1)
      r2 = SuperAuth::Group.create(name: "r2")
      SuperAuth::Group.create(name: "c2", parent: r2)

      expect(r1.descendants_dataset.map(:id)).to match_array [r1.id, c1.id]
    end

    it "A3: a child's descendants exclude its parent and siblings" do
      pending "A3: a child is anchored on its parent's id, so the parent's whole subtree comes back"
      r1 = SuperAuth::Group.create(name: "r1")
      c1 = SuperAuth::Group.create(name: "c1", parent: r1)
      SuperAuth::Group.create(name: "c2", parent: r1)
      gc = SuperAuth::Group.create(name: "gc", parent: c1)

      expect(c1.descendants_dataset.map(:id)).to match_array [c1.id, gc.id]
    end

    it "A3: (ActiveRecord) a root's descendants exclude the other trees in the forest" do
      pending "A3: same anchor as the Sequel model; the ActiveRecord model wraps the same CTE"
      r1 = SuperAuth::ActiveRecord::Group.create!(name: "r1")
      c1 = SuperAuth::ActiveRecord::Group.create!(name: "c1", parent: r1)
      r2 = SuperAuth::ActiveRecord::Group.create!(name: "r2")
      SuperAuth::ActiveRecord::Group.create!(name: "c2", parent: r2)

      expect(r1.descendants_dataset.map(&:id)).to match_array [r1.id, c1.id]
    end

    it "A3: (roles) a child's descendants exclude its parent and siblings" do
      pending "A3: roles share the Nestable code path"
      r1 = SuperAuth::Role.create(name: "r1")
      c1 = SuperAuth::Role.create(name: "c1", parent: r1)
      SuperAuth::Role.create(name: "c2", parent: r1)
      gc = SuperAuth::Role.create(name: "gc", parent: c1)

      expect(c1.descendants_dataset.map(:id)).to match_array [c1.id, gc.id]
    end
  end

  describe "A4: tree and DISTINCT semantics that must not regress" do
    it "A4: ancestors_dataset returns the node and its ancestors, nothing else" do
      r1 = SuperAuth::Group.create(name: "r1")
      c1 = SuperAuth::Group.create(name: "c1", parent: r1)
      SuperAuth::Group.create(name: "c2", parent: r1)
      gc = SuperAuth::Group.create(name: "gc", parent: c1)
      SuperAuth::Group.create(name: "other")

      expect(gc.ancestors_dataset.map(:id)).to match_array [gc.id, c1.id, r1.id]
    end

    it "A4: duplicate user->group edges yield one authorization row" do
      user = SuperAuth::User.create(name: "u")
      group = SuperAuth::Group.create(name: "g")
      role = SuperAuth::Role.create(name: "r")
      permission = SuperAuth::Permission.create(name: "p")
      resource = SuperAuth::Resource.create(name: "res")
      2.times { SuperAuth::Edge.create(user: user, group: group) }
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      expect(grants).to eq [["u", "g", "r", "p", "res"]]
    end

    it "A4: a role attached to both an ancestor and the member's own group yields one row" do
      user = SuperAuth::User.create(name: "u")
      parent = SuperAuth::Group.create(name: "parent")
      child = SuperAuth::Group.create(name: "child", parent: parent)
      role = SuperAuth::Role.create(name: "r")
      permission = SuperAuth::Permission.create(name: "p")
      resource = SuperAuth::Resource.create(name: "res")
      SuperAuth::Edge.create(user: user, group: child)
      SuperAuth::Edge.create(group: parent, role: role)
      SuperAuth::Edge.create(group: child, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      expect(grants).to eq [["u", "child", "r", "p", "res"]]
    end

    it "A4: the same authorization reached through two strategies is one row in the union" do
      user = SuperAuth::User.create(name: "u")
      group = SuperAuth::Group.create(name: "g")
      permission = SuperAuth::Permission.create(name: "p")
      resource = SuperAuth::Resource.create(name: "res")
      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)  # strategy 3
      SuperAuth::Edge.create(user: user, permission: permission)    # strategy 4
      SuperAuth::Edge.create(permission: permission, resource: resource)

      rows = SuperAuth::Edge.authorizations.all.map { |a| [a[:user_name], a[:group_name], a[:permission_name], a[:resource_name]] }
      expect(rows).to match_array [["u", "g", "p", "res"], ["u", nil, "p", "res"]]
    end
  end

  describe "A5: edges no strategy reads" do
    it "A5: a group -> resource edge either authorizes the group's members or is rejected" do
      pending "A5: no strategy reads group->resource edges; the edge is accepted and silently inert"
      user = SuperAuth::User.create(name: "u")
      group = SuperAuth::Group.create(name: "g")
      resource = SuperAuth::Resource.create(name: "res")
      SuperAuth::Edge.create(user: user, group: group)
      created = begin
        SuperAuth::Edge.create(group: group, resource: resource)
        true
      rescue StandardError
        false
      end

      expect(grants.map { |g| [g[0], g[4]] }).to eq [["u", "res"]] if created
    end

    it "A5: a role -> resource edge either authorizes the role's holders or is rejected" do
      pending "A5: no strategy reads role->resource edges; the edge is accepted and silently inert"
      user = SuperAuth::User.create(name: "u")
      role = SuperAuth::Role.create(name: "r")
      resource = SuperAuth::Resource.create(name: "res")
      SuperAuth::Edge.create(user: user, role: role)
      created = begin
        SuperAuth::Edge.create(role: role, resource: resource)
        true
      rescue StandardError
        false
      end

      expect(grants.map { |g| [g[0], g[4]] }).to eq [["u", "res"]] if created
    end
  end

  describe "A6: path column width" do
    # The audit predicted a 4,000-character cap on MySQL from the char(4000)
    # anchor cast. It does not exist: MySQL promotes char(4000) to text, so the
    # real ceiling is text's 65,535 bytes. This pins that 17 x 255 works
    # everywhere; the ceiling itself is documented, not tested.
    it "A6: keeps full name paths through 17 levels of 255-character names" do
      names = (1..17).map { |i| i.to_s.rjust(255, "x") }
      parent = nil
      groups = names.map { |n| parent = SuperAuth::Group.create(name: n, parent: parent) }

      leaf = SuperAuth::Group.trees.where(id: groups.last.id).first
      expect(leaf[:group_name_path]).to eq names.join(",")
      expect(leaf[:group_path]).to eq groups.map(&:id).join(",")
    end
  end
end
