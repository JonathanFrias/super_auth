require 'spec_helper'

RSpec.describe "SuperAuth Flaw Fixes" do
  let(:db) { SuperAuth.db }

  # These tests verify the fixes for the 5 flaws identified in the code review.
  # Flaws 2, 3, 4, 7, 9 were determined to be by-design or acceptable trade-offs.

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_edges].delete
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  after do
    SuperAuth.uninstall_migrations
  end

  describe "Fix 1: current_user is now thread-safe" do
    it "each thread maintains its own current_user via Thread.current" do
      alice = SuperAuth::User.create(name: "Alice")
      bob = SuperAuth::User.create(name: "Bob")

      observed_users = []
      barrier = Queue.new

      thread_a = Thread.new do
        SuperAuth.current_user = alice
        barrier.push(:ready)     # signal thread B to set its user
        sleep 0.05               # give thread B time to set bob
        observed_users << [:thread_a, SuperAuth.current_user]
      end

      thread_b = Thread.new do
        barrier.pop              # wait for thread A to finish setting alice
        SuperAuth.current_user = bob
        observed_users << [:thread_b, SuperAuth.current_user]
      end

      thread_a.join
      thread_b.join

      thread_a_observation = observed_users.find { |name, _| name == :thread_a }
      thread_b_observation = observed_users.find { |name, _| name == :thread_b }

      # Thread A still sees Alice despite Thread B setting Bob
      expect(thread_a_observation[1].name).to eq("Alice"),
        "Thread A should still see Alice -- thread-local storage prevents cross-thread leaks"
      expect(thread_b_observation[1].name).to eq("Bob"),
        "Thread B should see Bob"
    end
  end

  describe "Fix 5: with_roles now uses correct table aliases" do
    it "with_roles works without error and returns correct data" do
      user = SuperAuth::User.create(name: "Alice")
      role = SuperAuth::Role.create(name: "Dev")
      SuperAuth::Edge.create(user: user, role: role)

      # with_groups still works
      group = SuperAuth::Group.create(name: "Eng")
      SuperAuth::Edge.create(user: user, group: group)
      expect { SuperAuth::User.with_groups.all }.not_to raise_error

      # with_roles now works too (previously raised Sequel::DatabaseError)
      results = nil
      expect { results = SuperAuth::User.with_roles.all }.not_to raise_error

      expect(results.length).to eq(1)
      expect(results.first[:user_name]).to eq("Alice")
      expect(results.first[:role_name]).to eq("Dev")
    end
  end

  describe "Fix 6: Edges table now has indexes" do
    it "super_auth_edges has indexes on all 5 foreign key columns" do
      indexes = db.indexes(:super_auth_edges)

      indexed_columns = indexes.values.flat_map { |info| info[:columns] }

      expect(indexed_columns).to include(:user_id)
      expect(indexed_columns).to include(:group_id)
      expect(indexed_columns).to include(:role_id)
      expect(indexed_columns).to include(:permission_id)
      expect(indexed_columns).to include(:resource_id)
    end
  end

  describe "Fix 8: Consistent NULL placeholder values across all strategies" do
    before do
      @user = SuperAuth::User.create(name: "Alice")
      @perm = SuperAuth::Permission.create(name: "read")
      @resource = SuperAuth::Resource.create(name: "docs")
      @group = SuperAuth::Group.create(name: "Eng")
      @role = SuperAuth::Role.create(name: "Dev")

      # Strategy 2 path: user -> role -> permission -> resource
      SuperAuth::Edge.create(user: @user, role: @role)
      SuperAuth::Edge.create(role: @role, permission: @perm)
      SuperAuth::Edge.create(permission: @perm, resource: @resource)
    end

    it "strategy 2 uses NULL for all missing group fields" do
      results = SuperAuth::Edge.users_roles_permissions_resources.all
      row = results.first

      expect(row[:group_id]).to be_nil
      expect(row[:group_name]).to be_nil
      expect(row[:group_path]).to be_nil
      expect(row[:group_name_path]).to be_nil
      expect(row[:group_parent_id]).to be_nil
      expect(row[:group_created_at]).to be_nil
      expect(row[:group_updated_at]).to be_nil
    end

    it "strategy 3 uses NULL for all missing role fields" do
      # Need a group-based path for strategy 3
      user2 = SuperAuth::User.create(name: "Bob")
      SuperAuth::Edge.create(user: user2, group: @group)
      SuperAuth::Edge.create(group: @group, permission: @perm)

      results = SuperAuth::Edge.users_groups_permissions_resources.all
      row = results.find { |r| r[:user_id] == user2.id }

      expect(row[:role_id]).to be_nil
      expect(row[:role_name]).to be_nil
      expect(row[:role_path]).to be_nil
      expect(row[:role_name_path]).to be_nil
      expect(row[:role_parent_id]).to be_nil
      expect(row[:role_created_at]).to be_nil
      expect(row[:role_updated_at]).to be_nil
    end

    it "strategy 4 uses NULL for all missing group and role fields" do
      # Need a user->permission->resource path (no group or role)
      user3 = SuperAuth::User.create(name: "Carol")
      SuperAuth::Edge.create(user: user3, permission: @perm)

      results = SuperAuth::Edge.users_permissions_resources.all
      row = results.find { |r| r[:user_id] == user3.id }

      expect(row[:group_id]).to be_nil
      expect(row[:group_created_at]).to be_nil
      expect(row[:role_id]).to be_nil
      expect(row[:role_created_at]).to be_nil
    end

    it "strategy 5 uses NULL for all missing group, role, and permission fields" do
      # Direct user->resource path
      user4 = SuperAuth::User.create(name: "Dave")
      SuperAuth::Edge.create(user: user4, resource: @resource)

      results = SuperAuth::Edge.users_resources.all
      row = results.find { |r| r[:user_id] == user4.id }

      expect(row[:group_id]).to be_nil
      expect(row[:group_created_at]).to be_nil
      expect(row[:role_id]).to be_nil
      expect(row[:role_created_at]).to be_nil
      expect(row[:permission_id]).to be_nil
      expect(row[:permission_created_at]).to be_nil
    end

    it "no strategy uses hardcoded epoch timestamps or literal 0 for missing fields" do
      sql = SuperAuth::Edge.authorizations.sql
      expect(sql).not_to include("1970-01-01"),
        "No strategy should use hardcoded epoch timestamps"
      expect(sql).not_to match(/\b0 as "/i),
        "No strategy should use literal 0 for missing IDs"
    end
  end

  describe "Fix 10: Database fallback now warns instead of silently degrading" do
    it "uses warn (STDERR) instead of puts (STDOUT) for fallback messages" do
      source = File.read(File.join(Gem::Specification.find_by_name("super_auth").gem_dir,
        "lib", "super_auth.rb"))

      # No more silent puts
      expect(source).not_to include('puts "ActiveRecord database could not be found'),
        "Should not use puts for database fallback warning"
      expect(source).not_to include('puts "ENV SUPER_AUTH_DATABASE_URL not set'),
        "Should not use puts for missing URL warning"

      # Uses warn instead (goes to STDERR, harder to miss)
      expect(source).to include("[SuperAuth] WARNING:"),
        "Should use warn with [SuperAuth] prefix for visibility"
    end

    it "raises in Rails production instead of falling back" do
      source = File.read(File.join(Gem::Specification.find_by_name("super_auth").gem_dir,
        "lib", "super_auth.rb"))

      expect(source).to include("!Rails.env.local?"),
        "Should raise in non-local Rails environments (production, staging)"
      expect(source).to include("raise Error"),
        "Should raise SuperAuth::Error when no database is configured in production"
    end
  end
end
