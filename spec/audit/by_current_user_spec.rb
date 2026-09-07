require "spec_helper"
require "active_record"

# Findings from the September 2026 test audit, pinned as specs. Nothing here is
# fixed yet. See spec/audit/graph_spec.rb for the pending/tripwire convention and
# ~/.claude/plans/superauth-audit-fix-handoff.md for the full context (B1, B2,
# ... match the tags in the titles).

# A current_user whose class SuperAuth has never seen (anonymous classes have no name).
AuditOtherUser = Struct.new(:id)

RSpec.describe "Audit: ByCurrentUser and Authorization.compile!" do
  let(:db) { SuperAuth.db }

  def reset_super_auth_column_information
    return unless defined?(SuperAuth::ActiveRecord::Authorization)

    [SuperAuth::ActiveRecord::Authorization, SuperAuth::ActiveRecord::Edge,
     SuperAuth::ActiveRecord::Group, SuperAuth::ActiveRecord::Permission,
     SuperAuth::ActiveRecord::Resource, SuperAuth::ActiveRecord::Role,
     SuperAuth::ActiveRecord::User].each(&:reset_column_information)
  end

  # The app tables here use integer primary keys, so the default install is
  # :bigint external id columns (what an int-pk app configures). B8 opts into
  # the gem's default :string to show what happens when nobody configures it.
  around do |example|
    SuperAuth.external_id_type = example.metadata[:external_id_type] || :bigint
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    SuperAuth.install_migrations
    SuperAuth.load
    reset_super_auth_column_information
    SuperAuth::ActiveRecord::Authorization.delete_all
    SuperAuth::ActiveRecord::Edge.delete_all
    SuperAuth::ActiveRecord::Group.update_all(parent_id: nil)
    SuperAuth::ActiveRecord::Group.delete_all
    SuperAuth::ActiveRecord::User.delete_all
    SuperAuth::ActiveRecord::Permission.delete_all
    SuperAuth::ActiveRecord::Role.update_all(parent_id: nil)
    SuperAuth::ActiveRecord::Role.delete_all
    SuperAuth::ActiveRecord::Resource.delete_all

    case db.database_type
    when :mysql, :mysql2
      db.run "create table if not exists resources (id integer primary key auto_increment, name varchar(255))"
      db.run "create table if not exists external_users (id integer primary key auto_increment, name varchar(255))"
    when :postgres
      db.run "create table if not exists resources (id serial primary key, name varchar(255))"
      db.run "create table if not exists external_users (id serial primary key, name varchar(255))"
    else
      db.run "create table if not exists resources (id integer primary key, name varchar(255))"
      db.run "create table if not exists external_users (id integer primary key, name varchar(255))"
    end
    db[:resources].delete
    db[:external_users].delete

    example.run

    SuperAuth.uninstall_migrations
  ensure
    SuperAuth.current_user = nil
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
    end
  end

  let(:external_user_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = :external_users
      include SuperAuth::ActiveRecord::ByCurrentUser

      def self.name
        "ExternalUser"
      end
    end
  end

  def grant(user, record)
    SuperAuth::ActiveRecord::Authorization.create!(user_id: user.id, resource_external_type: "Resource", resource_external_id: record.id)
  end

  describe "B1: the system identity" do
    it "B1: SuperAuth::ActiveRecord::User.system sees every record" do
      resource_class.create!(name: "r1")
      resource_class.create!(name: "r2")
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.system

      expect(resource_class.count).to eq 2
    end

    it "B1: the Sequel SuperAuth::User.system that USAGE.md recommends sees every record" do
      resource_class.create!(name: "r1")
      SuperAuth.current_user = SuperAuth::User.system

      expect(resource_class.count).to eq 1
    end

    it "B1: system? looks the system user up without creating it" do
      ar_user = SuperAuth::ActiveRecord::User.create!(name: "someone")
      sequel_user = SuperAuth::User.create(name: "someone else")

      expect(ar_user.system?).to be false
      expect(sequel_user.system?).to be false
      expect(SuperAuth::ActiveRecord::User.where(name: "system")).not_to exist
    end

    it "B1: a user record that merely has the name \"system\" does not bypass the scope" do
      pending "B1: system? is `name == \"system\"` on a nullable, non-unique, user-writable column; whoever is named system first is the system user"
      impostor = SuperAuth::ActiveRecord::User.create!(name: "system") # created by the app, an import, or the graph UI
      resource_class.create!(name: "r1")
      SuperAuth.current_user = impostor

      expect(resource_class.all.to_a).to be_empty
    end
  end

  describe "B2: which current_user classes count as internal" do
    it "B2: a Sequel SuperAuth::User is matched on user_id like its ActiveRecord twin" do
      pending "B2: ByCurrentUser only recognises SuperAuth::ActiveRecord::User; a Sequel SuperAuth::User is treated as external and silently sees nothing (RLS accepts both)"
      user = SuperAuth::User.create(name: "sequel user")
      r1 = resource_class.create!(name: "r1")
      grant(user, r1)
      SuperAuth.current_user = user

      expect(resource_class.all.map(&:id)).to eq [r1.id]
    end
  end

  describe "B3: write scoping (all_queries: true)" do
    it "B3: update_all and delete_all touch only authorized rows" do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create!(name: "regular")
      r1 = resource_class.create!(name: "r1")
      r2 = resource_class.create!(name: "r2")
      grant(SuperAuth.current_user, r1)

      expect(resource_class.update_all(name: "renamed")).to eq 1
      expect(resource_class.unscoped.find(r2.id).name).to eq "r2"
      expect(resource_class.delete_all).to eq 1
      expect(resource_class.unscoped.pluck(:id)).to eq [r2.id]
    end

    it "B3: update_all and delete_all touch nothing when nobody is logged in" do
      resource_class.create!(name: "r1")
      SuperAuth.current_user = nil

      expect(resource_class.update_all(name: "renamed")).to eq 0
      expect(resource_class.delete_all).to eq 0
      expect(resource_class.unscoped.count).to eq 1
    end
  end

  describe "B4: external (application) users" do
    it "B4: an external user sees exactly the records compiled for its id and type" do
      ext = external_user_class.create!(name: "e")
      mirror = SuperAuth::ActiveRecord::User.create!(name: "e", external_id: ext.id, external_type: "ExternalUser")
      r1 = resource_class.create!(name: "r1")
      resource_class.create!(name: "r2")
      registered = SuperAuth::ActiveRecord::Resource.create!(name: "r1", external_id: r1.id, external_type: "Resource")
      SuperAuth::ActiveRecord::Edge.create!(user: mirror, resource: registered)
      SuperAuth::ActiveRecord::Authorization.compile!

      SuperAuth.current_user = ext
      expect(resource_class.all.map(&:id)).to eq [r1.id]

      SuperAuth.current_user = AuditOtherUser.new(ext.id) # same id, different class
      expect(resource_class.all.to_a).to be_empty
    end
  end

  describe "B5: compile!" do
    def two_row_graph
      user = SuperAuth::ActiveRecord::User.create!(name: "u")
      %w[a b].each do |name|
        record = resource_class.create!(name: name)
        registered = SuperAuth::ActiveRecord::Resource.create!(name: name, external_id: record.id, external_type: "Resource")
        SuperAuth::ActiveRecord::Edge.create!(user: user, resource: registered)
      end
      user
    end

    it "B5: leaves the previous table intact when an insert fails part-way" do
      two_row_graph
      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq 2

      calls = 0
      allow(SuperAuth::ActiveRecord::Authorization).to receive(:create!).and_wrap_original do |original, *args|
        calls += 1
        raise "boom" if calls == 2
        original.call(*args)
      end

      expect { SuperAuth::ActiveRecord::Authorization.compile! }.to raise_error(RuntimeError, "boom")
      expect(SuperAuth::ActiveRecord::Authorization.count).to eq 2
    end

    it "B5: on an empty graph empties the table and returns 0" do
      two_row_graph
      SuperAuth::ActiveRecord::Authorization.compile!
      SuperAuth::ActiveRecord::Edge.delete_all

      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq 0
      expect(SuperAuth::ActiveRecord::Authorization.count).to eq 0
    end

    it "B5: drops a row after its user->resource edge is deleted" do
      user = two_row_graph
      SuperAuth::ActiveRecord::Authorization.compile!
      gone = SuperAuth::ActiveRecord::Resource.find_by!(name: "a")
      SuperAuth::ActiveRecord::Edge.where(user: user, resource: gone).delete_all

      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq 1
      SuperAuth.current_user = user
      expect(resource_class.all.map(&:name)).to eq ["b"]
    end
  end

  describe "B6: type-level wildcard produced by compile!" do
    it "B6: a resource registered with a type but no id compiles to a wildcard for that type" do
      resource_class.create!(name: "r1")
      resource_class.create!(name: "r2")
      admin = SuperAuth::ActiveRecord::User.create!(name: "admin")
      every_resource = SuperAuth::ActiveRecord::Resource.create!(name: "all resources", external_type: "Resource")
      SuperAuth::ActiveRecord::Edge.create!(user: admin, resource: every_resource)
      SuperAuth::ActiveRecord::Authorization.compile!

      SuperAuth.current_user = admin
      expect(resource_class.count).to eq 2
    end
  end

  describe "B7: records loaded through unscoped" do
    it "B7: destroying a record outside the scope leaves the row in place" do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create!(name: "regular")
      r1 = resource_class.create!(name: "r1")
      r2 = resource_class.create!(name: "r2")
      grant(SuperAuth.current_user, r1)

      resource_class.unscoped.find(r2.id).destroy
      expect(resource_class.unscoped.exists?(r2.id)).to be true
    end

    it "B7: destroy and update outside the scope report failure instead of success" do
      pending "B7: the scoped DELETE/UPDATE affects 0 rows and ActiveRecord does not check affected rows, so destroy/update return success"
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create!(name: "regular")
      r1 = resource_class.create!(name: "r1")
      r2 = resource_class.create!(name: "r2")
      grant(SuperAuth.current_user, r1)

      outsider = resource_class.unscoped.find(r2.id)
      expect(outsider.update(name: "renamed")).to be false
      expect { outsider.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end
  end

  describe "B8: the default external_id_type (:string) against integer primary keys", external_id_type: :string do
    it "B8: an external id that is not exactly the record's id never matches" do
      case db.database_type
      when :mysql, :mysql2
        pending "B8: MySQL coerces '1x' to 1 (warning 1292) and returns the record"
      when :postgres
        pending "B8: Postgres raises 'operator does not exist: integer = character varying' instead of a clear configuration error"
      end
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create!(name: "u")
      r1 = resource_class.create!(name: "r1")
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id, resource_external_type: "Resource", resource_external_id: "#{r1.id}x"
      )

      expect(resource_class.all.to_a).to be_empty
    end
  end
end
