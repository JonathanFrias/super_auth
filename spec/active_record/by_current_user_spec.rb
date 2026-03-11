require "spec_helper"
require "active_record" unless Gem::Specification.find_by_name("activerecord").nil?

RSpec.describe SuperAuth do
  let(:db) { SuperAuth.db }

  around do |example|
    SuperAuth.install_migrations
    SuperAuth.load
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
end
