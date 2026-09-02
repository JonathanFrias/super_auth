require "spec_helper"
require "active_record" unless Gem::Specification.find_by_name("activerecord").nil?

RSpec.describe SuperAuth do
  let(:db) { SuperAuth.db }

  # The around hook below swaps the external id columns between :integer and
  # :string, so cached column types must be dropped on the way in and out.
  def reset_super_auth_column_information
    return unless defined?(SuperAuth::ActiveRecord::Authorization)

    [SuperAuth::ActiveRecord::Authorization, SuperAuth::ActiveRecord::Edge,
     SuperAuth::ActiveRecord::Group, SuperAuth::ActiveRecord::Permission,
     SuperAuth::ActiveRecord::Resource, SuperAuth::ActiveRecord::Role,
     SuperAuth::ActiveRecord::User].each(&:reset_column_information)
  end

  around do |example|
    # These specs use integer-pk app tables, so install with matching
    # external id columns (what a real int-pk app configures). Earlier spec
    # groups may have left tables built with the default :string columns and
    # install_migrations is a no-op when tables exist — reinstall so the
    # configured type actually applies.
    SuperAuth.external_id_type = :bigint
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    SuperAuth.install_migrations
    SuperAuth.load
    reset_super_auth_column_information
    SuperAuth::ActiveRecord::Edge.delete_all
    SuperAuth::ActiveRecord::Group.delete_all
    SuperAuth::ActiveRecord::User.delete_all
    SuperAuth::ActiveRecord::Permission.delete_all
    SuperAuth::ActiveRecord::Role.delete_all
    SuperAuth::ActiveRecord::Resource.delete_all

    # Create tables with database-appropriate auto-increment syntax
    case SuperAuth.db.database_type
    when :mysql, :mysql2
      SuperAuth.db.run "create table if not exists resources (id integer primary key auto_increment, name varchar(255))"
      SuperAuth.db.run "create table if not exists external_users (id integer primary key auto_increment, name varchar(255))"
    when :postgres
      SuperAuth.db.run "create table if not exists resources (id serial primary key, name varchar(255))"
      SuperAuth.db.run "create table if not exists external_users (id serial primary key, name varchar(255))"
    else # SQLite
      SuperAuth.db.run "create table if not exists resources (id integer primary key, name varchar(255))"
      SuperAuth.db.run "create table if not exists external_users (id integer primary key, name varchar(255))"
    end

    # SuperAuth::ActiveRecord::User.itself # Loads if it it hasn't been loaded yet. TODO: Make this the normal ApplicationRecord rails style

    example.run

    SuperAuth.uninstall_migrations
  ensure
    SuperAuth.external_id_type = :string
    reset_super_auth_column_information
  end

  let(:resource_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = :resources
      include SuperAuth::ActiveRecord::ByCurrentUser

      def self.name
        "Resource"
      end

      def system?
        false
      end
    end
  end

  context "when not logged in" do
    before do
      SuperAuth.current_user = nil
    end

    it "returns no records" do
      expect(resource_class.all.to_a).to eq([])
    end

    context "with missing_user_behavior = :raise" do
      around do |example|
        SuperAuth.missing_user_behavior = :raise
        example.run
      ensure
        SuperAuth.missing_user_behavior = :none
      end

      it "raises SuperAuth::Error" do
        expect { resource_class.all.to_a }.to raise_error(SuperAuth::Error, "SuperAuth.current_user not set")
      end
    end
  end

  describe ".missing_user_behavior" do
    it "defaults to :none" do
      expect(SuperAuth.missing_user_behavior).to eq(:none)
    end

    it "accepts :raise" do
      SuperAuth.missing_user_behavior = :raise
      expect(SuperAuth.missing_user_behavior).to eq(:raise)
    ensure
      SuperAuth.missing_user_behavior = :none
    end

    it "rejects invalid values" do
      expect { SuperAuth.missing_user_behavior = :invalid }.to raise_error(ArgumentError, /must be :none or :raise/)
    end
  end

  context "when logged in" do
    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "name")
    end

    let(:external_user_resource) do
      Class.new(ActiveRecord::Base) do
        self.table_name = :external_users
        include SuperAuth::ActiveRecord::ByCurrentUser

        def self.name
          "ExternalUser"
        end
      end
    end

    let(:external_instance) { external_user_resource.create(name: "external user") }

    it "Can load the activerecord module" do
      # Verify SQL structure rather than exact string match (database-agnostic)
      sql = resource_class.limit(10).to_sql

      expect(sql).to include("SELECT")
      expect(sql).to include("resources")
      expect(sql).to include("super_auth_authorizations")
      expect(sql).to include("resource_external_id")
      expect(sql).to include("user_id")
      expect(sql).to include(SuperAuth.current_user.id.to_s)
      expect(sql).to include("Resource")
      expect(sql).to include("LIMIT 10")
    end

    it "allows logging in with the external user" do
      SuperAuth.current_user = external_user_resource.create(name: "external user")

      # Verify SQL structure rather than exact string match (database-agnostic)
      sql = resource_class.limit(10).to_sql

      expect(sql).to include("SELECT")
      expect(sql).to include("resources")
      expect(sql).to include("super_auth_authorizations")
      expect(sql).to include("resource_external_id")
      expect(sql).to include("user_external_id")
      expect(sql).to include(SuperAuth.current_user.id.to_s)
      expect(sql).to include("ExternalUser")
      expect(sql).to include("Resource")
      expect(sql).to include("LIMIT 10")
    end

    it "authenticates via the normal way" do
      group = SuperAuth::ActiveRecord::Group.create(name: "group")

      resource = SuperAuth::ActiveRecord::Resource.create(name: "resource", external: external_instance)
      permission = SuperAuth::ActiveRecord::Permission.create(name: "permission")

      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, group:)
      SuperAuth::ActiveRecord::Edge.create!(permission:, group:)
      SuperAuth::ActiveRecord::Edge.create!(permission:, resource:)

      expect(SuperAuth::ActiveRecord::Edge.authorizations.count).to eq 1
    end
  end

  context "type-level authorization (admin wildcard)" do
    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "admin")
      resource_class.unscoped.delete_all
    end

    it "returns all records when user has type-level authorization" do
      # Create some records
      resource_class.create!(name: "r1")
      resource_class.create!(name: "r2")

      # Insert a type-level authorization row (resource_external_id IS NULL)
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "Resource",
        resource_external_id: nil
      )

      results = resource_class.all.to_a
      expect(results.length).to eq(2)
    end
  end

  context "per-record authorization" do
    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "regular")
      resource_class.unscoped.delete_all
    end

    it "returns only authorized records" do
      r1 = resource_class.create!(name: "r1")
      resource_class.create!(name: "r2")
      r3 = resource_class.create!(name: "r3")

      # Authorize only r1 and r3
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "Resource",
        resource_external_id: r1.id.to_s
      )
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "Resource",
        resource_external_id: r3.id.to_s
      )

      results = resource_class.all.to_a
      expect(results.length).to eq(2)
      expect(results.map(&:name).sort).to eq(["r1", "r3"])
    end

    it "returns no records when user has no authorizations" do
      resource_class.create!(name: "r1")

      results = resource_class.all.to_a
      expect(results).to be_empty
    end
  end

  context "permission-gated subclasses" do
    let(:restart_class) do
      Class.new(resource_class) do
        def self.name
          "ResourceRestartPermission"
        end

        def restart!
          "restarted"
        end
      end
    end

    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "operator")
      resource_class.unscoped.delete_all
    end

    it "queries authorizations by the subclass's own name" do
      sql = restart_class.limit(1).to_sql

      expect(sql).to include("ResourceRestartPermission")
    end

    it "does not let base class grants flow down to the subclass" do
      record = resource_class.create!(name: "server")
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "Resource",
        resource_external_id: record.id.to_s
      )

      expect(resource_class.all.map(&:id)).to eq([record.id])
      expect(restart_class.all.to_a).to be_empty
      expect { restart_class.find(record.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "loads the subclass once access is approved explicitly" do
      record = resource_class.create!(name: "server")
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "ResourceRestartPermission",
        resource_external_id: record.id.to_s
      )

      expect(restart_class.find(record.id).restart!).to eq("restarted")
      # The subclass grant does not flow up to the base class either.
      expect(resource_class.all.to_a).to be_empty
    end

    it "approves subclass access via the edge graph" do
      record = resource_class.create!(name: "server")
      permission = SuperAuth::ActiveRecord::Permission.create!(name: "restart")
      resource = SuperAuth::ActiveRecord::Resource.create!(
        name: "restartable servers", external_id: record.id, external_type: "ResourceRestartPermission"
      )
      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, permission:)
      SuperAuth::ActiveRecord::Edge.create!(permission:, resource:)
      SuperAuth::ActiveRecord::Authorization.compile!

      expect(restart_class.find(record.id).restart!).to eq("restarted")
    end

    it "supports type-level approval of the subclass" do
      record = resource_class.create!(name: "server")
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id,
        resource_external_type: "ResourceRestartPermission",
        resource_external_id: nil
      )

      expect(restart_class.all.map(&:id)).to eq([record.id])
    end
  end

  context "cross-group role isolation through the compiled table" do
    # Two orgs, each with its own reps group holding its own role. The scope
    # must hand each rep only the record their own org's role reaches.
    before do
      @alice = SuperAuth::ActiveRecord::User.create(name: "alice")
      @bob = SuperAuth::ActiveRecord::User.create(name: "bob")
      SuperAuth.current_user = @alice
      resource_class.unscoped.delete_all
      @record_a = resource_class.create!(name: "org1 claim")
      @record_b = resource_class.create!(name: "org2 claim")

      org1 = SuperAuth::ActiveRecord::Group.create(name: "Org1")
      org1_reps = SuperAuth::ActiveRecord::Group.create(name: "Org1/Reps", parent: org1)
      org2 = SuperAuth::ActiveRecord::Group.create(name: "Org2")
      org2_reps = SuperAuth::ActiveRecord::Group.create(name: "Org2/Reps", parent: org2)
      role1 = SuperAuth::ActiveRecord::Role.create(name: "Org1 Rep Role")
      role2 = SuperAuth::ActiveRecord::Role.create(name: "Org2 Rep Role")
      write1 = SuperAuth::ActiveRecord::Permission.create(name: "org1:claim_write")
      write2 = SuperAuth::ActiveRecord::Permission.create(name: "org2:claim_write")
      resource_a = SuperAuth::ActiveRecord::Resource.create(name: "claim", external_id: @record_a.id, external_type: "Resource")
      resource_b = SuperAuth::ActiveRecord::Resource.create(name: "claim", external_id: @record_b.id, external_type: "Resource")

      SuperAuth::ActiveRecord::Edge.create!(user: @alice, group: org1_reps)
      SuperAuth::ActiveRecord::Edge.create!(user: @bob, group: org2_reps)
      SuperAuth::ActiveRecord::Edge.create!(group: org1_reps, role: role1)
      SuperAuth::ActiveRecord::Edge.create!(group: org2_reps, role: role2)
      SuperAuth::ActiveRecord::Edge.create!(role: role1, permission: write1)
      SuperAuth::ActiveRecord::Edge.create!(role: role2, permission: write2)
      SuperAuth::ActiveRecord::Edge.create!(permission: write1, resource: resource_a)
      SuperAuth::ActiveRecord::Edge.create!(permission: write2, resource: resource_b)
      SuperAuth::ActiveRecord::Authorization.compile!
    end

    it "compiles exactly one authorization per rep" do
      expect(SuperAuth::ActiveRecord::Authorization.pluck(:user_id, :resource_external_id).sort).to eq [
        [@alice.id, @record_a.id],
        [@bob.id, @record_b.id],
      ]
    end

    it "lets each rep load only their own org's record" do
      SuperAuth.current_user = @alice
      expect(resource_class.all.map(&:id)).to eq [@record_a.id]
      expect(resource_class.where(id: @record_b.id)).to be_empty

      SuperAuth.current_user = @bob
      expect(resource_class.all.map(&:id)).to eq [@record_b.id]
      expect(resource_class.where(id: @record_a.id)).to be_empty
    end
  end
end
