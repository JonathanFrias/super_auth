require "spec_helper"
require "active_record"
require "stringio"

# belongs_to :external resolves its class by name, so the stand-in for a
# host's model needs a real constant and a real table (as in label_spec).
class SuperAuthNestedSpecPost < ActiveRecord::Base
  self.table_name = "super_auth_nested_spec_posts"
end

# Resources nest like groups and roles (0.8.0): a grant on a node reaches the
# node and every node under it, through each of the five path strategies. A
# node with neither external_type nor external_id is a container. A node with
# an external_type and no external_id is a type-level (wildcard) node, which
# is deprecated and must stay flat.
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

  # A container holding two registered records. The records carry a type and
  # an id so the compiled rows show a descendant keeping its own columns; the
  # container carries neither.
  def container_with_records
    container = SuperAuth::Resource.create(name: "folder")
    a = SuperAuth::Resource.create(name: "a", external_type: "Document", external_id: "1", parent: container)
    b = SuperAuth::Resource.create(name: "b", external_type: "Document", external_id: "2", parent: container)
    [container, a, b]
  end

  # Both deprecators write to $stderr: ActiveSupport::Deprecation's default
  # behaviour and the stand-in SuperAuth::Deprecator alike.
  def capture_stderr
    previous = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = previous
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
  end

  describe "the wildcard deprecation" do
    # Silenced for the suite in spec_helper; audible here.
    around do |example|
      SuperAuth.deprecator.silenced = false
      example.run
    ensure
      SuperAuth.deprecator.silenced = true
    end

    it "warns once per compile, naming the wildcard node" do
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      SuperAuth::Edge.create(user: user, resource: wildcard)

      output = capture_stderr { SuperAuth::Authorization.compile! }
      expect(output).to match(/wildcard/).and match(/deprecated/)
      expect(output).to match(/^DEPRECATION WARNING: 1 type-level \(wildcard\) resource node \(external_type set, external_id NULL\): all docs \(#{wildcard.id}\)\. Wildcard nodes are deprecated\./)
      expect(output.scan("DEPRECATION WARNING").size).to eq 1
    end

    it "warns from the ActiveRecord twin as well" do
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      SuperAuth::Edge.create(user: user, resource: wildcard)

      output = capture_stderr { SuperAuth::ActiveRecord::Authorization.compile! }
      expect(output).to match(/wildcard/).and match(/deprecated/)
      expect(output).to include("all docs (#{wildcard.id})")
    end

    it "counts and lists every wildcard, granted or not" do
      SuperAuth::Resource.create(name: "all claims", external_type: "Claim")
      SuperAuth::Resource.create(name: "all docs", external_type: "Document")

      output = capture_stderr { SuperAuth::Authorization.compile! }
      expect(output).to match(/2 type-level \(wildcard\) resource nodes \(external_type set, external_id NULL\): all claims \(\d+\), all docs \(\d+\)\./)
    end

    it "says nothing for a graph of containers and records" do
      container, _a, _b = container_with_records
      SuperAuth::Edge.create(user: user, resource: container)

      expect(capture_stderr { SuperAuth::Authorization.compile! }).not_to include("DEPRECATION WARNING")
      expect(capture_stderr { SuperAuth::ActiveRecord::Authorization.compile! }).not_to include("DEPRECATION WARNING")
    end

    it "warns after the commit, so a raising deprecation reports a compile that happened" do
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")
      SuperAuth::Edge.create(user: user, resource: wildcard)
      previous = SuperAuth.deprecator
      SuperAuth.deprecator = ActiveSupport::Deprecation.new("1.0", "SuperAuth").tap { |d| d.behavior = :raise }

      expect { SuperAuth::Authorization.compile! }.to raise_error(ActiveSupport::DeprecationException)
      expect(db[:super_auth_authorizations].count).to eq 1
      expect { SuperAuth::ActiveRecord::Authorization.compile! }.to raise_error(ActiveSupport::DeprecationException)
      expect(db[:super_auth_authorizations].count).to eq 1
    ensure
      SuperAuth.deprecator = previous
    end
  end

  describe "SuperAuth.deprecator" do
    # This file requires active_record before spec_helper's before(:suite)
    # first touches SuperAuth.deprecator, so the memoized deprecator is an
    # ActiveSupport::Deprecation and a Rails host's deprecation config applies.
    it "is an ActiveSupport::Deprecation when ActiveSupport is loaded" do
      expect(SuperAuth.deprecator).to be_a(ActiveSupport::Deprecation)
    end

    it "can be replaced, and compile! warns through the replacement" do
      previous = SuperAuth.deprecator
      SuperAuth.deprecator = SuperAuth::Deprecator.new
      wildcard = SuperAuth::Resource.create(name: "all docs", external_type: "Document")

      output = capture_stderr { SuperAuth::Authorization.compile! }
      expect(output).to include(
        "DEPRECATION WARNING: 1 type-level (wildcard) resource node (external_type set, external_id NULL): " \
        "all docs (#{wildcard.id}). Wildcard nodes are deprecated. They still work, and they remain the only way " \
        "to authorize INSERT under row-level security; the successor is a grant on a parent record. See the CHANGELOG.\n"
      )
    ensure
      SuperAuth.deprecator = previous
    end

    describe "SuperAuth::Deprecator, the stand-in without ActiveSupport" do
      it "prints the message to stderr as a DEPRECATION WARNING" do
        expect(capture_stderr { SuperAuth::Deprecator.new.warn("gone soon") }).to include("DEPRECATION WARNING: gone soon\n")
      end

      it "prints nothing when silenced" do
        deprecator = SuperAuth::Deprecator.new
        deprecator.silenced = true

        expect(capture_stderr { deprecator.warn("gone soon") }).not_to include("DEPRECATION WARNING")
      end
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
