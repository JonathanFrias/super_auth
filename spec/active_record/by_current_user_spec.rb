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
    # MySQL checks the self-referencing parent_id key row by row, so detach
    # children before deleting the tree tables.
    SuperAuth::ActiveRecord::Group.update_all(parent_id: nil)
    SuperAuth::ActiveRecord::Group.delete_all
    SuperAuth::ActiveRecord::User.delete_all
    SuperAuth::ActiveRecord::Permission.delete_all
    SuperAuth::ActiveRecord::Role.update_all(parent_id: nil)
    SuperAuth::ActiveRecord::Role.delete_all
    SuperAuth::ActiveRecord::Resource.update_all(parent_id: nil)
    SuperAuth::ActiveRecord::Resource.delete_all

    # Create tables with database-appropriate auto-increment syntax. documents
    # carries a parent column of the external id type; mistyped_documents
    # carries one of the wrong type, for the preflight.
    pk =
    case SuperAuth.db.database_type
    when :mysql, :mysql2 then "integer primary key auto_increment"
    when :postgres then "serial primary key"
    else "integer primary key" # SQLite
    end
    SuperAuth.db.run "create table if not exists resources (id #{pk}, name varchar(255))"
    SuperAuth.db.run "create table if not exists external_users (id #{pk}, name varchar(255))"
    SuperAuth.db.run "create table if not exists documents (id #{pk}, name varchar(255), organization_id bigint)"
    SuperAuth.db.run "create table if not exists mistyped_documents (id #{pk}, name varchar(255), organization_id varchar(255))"

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

    # Containment is not inheritance: a compiled row copies the descendant
    # node's own external_type, so a container can hold the base node and the
    # capability node for one record and a single grant on it approves both.
    it "approves a base node and a capability node held by one container with one grant" do
      record = resource_class.create!(name: "server")
      servers = SuperAuth::ActiveRecord::Resource.create!(name: "servers")
      SuperAuth::ActiveRecord::Resource.create!(name: "server", external_id: record.id, external_type: "Resource", parent: servers)
      SuperAuth::ActiveRecord::Resource.create!(name: "restartable", external_id: record.id, external_type: "ResourceRestartPermission", parent: servers)
      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, resource: servers)
      SuperAuth::ActiveRecord::Authorization.compile!

      expect(resource_class.all.map(&:id)).to eq([record.id])
      expect(restart_class.find(record.id).restart!).to eq("restarted")
    end

    # The hazard that follows: the tree does not know a capability node from
    # any other child. Nested UNDER its base node, the capability node is
    # reached by every grant on the base node, which is exactly the flow-down
    # the subclass trick exists to prevent. Pinned as the documented rule
    # (keep capability nodes beside their base node, never under it), not as
    # desired behaviour.
    it "reaches a capability node nested under its base node from a grant on the base node (documented hazard)" do
      record = resource_class.create!(name: "server")
      base = SuperAuth::ActiveRecord::Resource.create!(name: "server", external_id: record.id, external_type: "Resource")
      SuperAuth::ActiveRecord::Resource.create!(name: "restartable", external_id: record.id, external_type: "ResourceRestartPermission", parent: base)
      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, resource: base)
      SuperAuth::ActiveRecord::Authorization.compile!

      expect(restart_class.find(record.id).restart!).to eq("restarted")
    end
  end

  context "container grants" do
    # A node with neither external_type nor external_id is a container. A
    # grant on it reaches every node under it, and each compiled row keeps
    # that node's own type and id, so the scope sees exactly the records
    # registered under the container.
    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "member")
      resource_class.unscoped.delete_all
    end

    it "makes the records registered under the container visible" do
      r1 = resource_class.create!(name: "r1")
      r2 = resource_class.create!(name: "r2")
      resource_class.create!(name: "r3") # never registered
      folder = SuperAuth::ActiveRecord::Resource.create!(name: "folder")
      [r1, r2].each do |record|
        SuperAuth::ActiveRecord::Resource.create!(name: record.name, external_id: record.id, external_type: "Resource", parent: folder)
      end
      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, resource: folder)

      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq(3)
      expect(resource_class.all.map(&:id)).to match_array([r1.id, r2.id])
    end

    # The container's own row has no external_type. Both branches of the
    # scope key on that column, so the row is not a wildcard for anything.
    it "grants nothing through the container's own row" do
      resource_class.create!(name: "unregistered")
      folder = SuperAuth::ActiveRecord::Resource.create!(name: "folder")
      SuperAuth::ActiveRecord::Edge.create!(user: SuperAuth.current_user, resource: folder)

      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq(1)
      expect(SuperAuth::ActiveRecord::Authorization.pluck(:resource_id, :resource_external_type, :resource_external_id)).to eq([[folder.id, nil, nil]])
      expect(resource_class.all.to_a).to be_empty
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

  context "parent-record grants" do
    # A document's tenancy is its organization_id. A grant on an organization
    # tier admits every document whose column names that organization; a
    # per-record grant on the document admits it whatever the column holds.
    def capture_sql
      statements = []
      callback = ->(_name, _started, _finished, _id, payload) do
        statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      statements
    end

    def quoted(table, column)
      connection = ActiveRecord::Base.connection
      "#{connection.quote_table_name(table)}.#{connection.quote_column_name(column)}"
    end

    def grant(type, id)
      SuperAuth::ActiveRecord::Authorization.create!(
        user_id: SuperAuth.current_user.id, resource_external_type: type, resource_external_id: id
      )
    end

    let(:document_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = :documents
        def self.name = "Document"
        super_auth parent: { column: :organization_id, resource_type: %w[Organization::Member Organization::Admin] }
      end
    end

    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "member")
      document_class.unscoped.delete_all
      @org1_doc = document_class.create!(name: "org1", organization_id: 1)
      @org2_doc = document_class.create!(name: "org2", organization_id: 2)
      @orphan = document_class.create!(name: "orphan", organization_id: nil)
    end

    it "stores the normalised reach on one default scope" do
      expect(document_class.super_auth_reach).to eq(id: ["Document"], organization_id: ["Organization::Member", "Organization::Admin"])
      expect(document_class.super_auth_reach).to be_frozen
      expect(document_class.super_auth_wildcard).to be true
      expect(document_class.default_scopes.size).to eq 1
    end

    it "refuses a malformed parent at declaration" do
      expect do
        Class.new(ActiveRecord::Base) do
          self.table_name = :documents
          def self.name = "Document"
          super_auth parent: { column: :id, resource_type: "Document" }
        end
      end.to raise_error(SuperAuth::Error, /column: :id is the per-record step/)
    end

    it "admits records through the parent column" do
      grant("Organization::Member", 1)

      expect(document_class.all.map(&:id)).to eq [@org1_doc.id]
      expect { document_class.find(@org2_doc.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "admits a per-record grant on a row whose parent column is NULL" do
      grant("Document", @orphan.id)

      expect(document_class.all.map(&:id)).to eq [@orphan.id]
    end

    it "admits through any type in the parent list" do
      grant("Organization::Admin", 1)

      expect(document_class.all.map(&:id)).to eq [@org1_doc.id]
    end

    # A type-level row on the parent type has a NULL id, and NULL equals no
    # column value: it is not a grant on every document of every organization.
    it "reaches nothing through a type-level row on the parent type" do
      grant("Organization::Member", nil)

      expect(document_class.all.to_a).to be_empty
    end

    it "keeps the type-level step on the class's own type" do
      grant("Document", nil)

      expect(document_class.all.map(&:id)).to match_array [@org1_doc.id, @org2_doc.id, @orphan.id]
    end

    it "lets the system user through" do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.system

      expect(document_class.count).to eq 3
    end

    it "keeps missing_user_behavior" do
      SuperAuth.current_user = nil
      expect(document_class.all.to_a).to eq []

      SuperAuth.missing_user_behavior = :raise
      expect { document_class.all.to_a }.to raise_error(SuperAuth::Error, "SuperAuth.current_user not set")
    ensure
      SuperAuth.missing_user_behavior = :none
    end

    it "loads a record in one statement holding both IN-subqueries, with no per-row query" do
      grant("Organization::Member", 1)
      grant("Document", @orphan.id)

      sql = document_class.where(id: @org1_doc.id).to_sql
      expect(sql).to include("#{quoted(:documents, :id)} IN (SELECT #{quoted(:super_auth_authorizations, :resource_external_id)} FROM")
      expect(sql).to include("#{quoted(:documents, :organization_id)} IN (SELECT #{quoted(:super_auth_authorizations, :resource_external_id)} FROM")
      expect(sql).to include("'Organization::Member', 'Organization::Admin'")
      expect(sql.scan("IN (SELECT").size).to eq 2
      expect(sql.scan("IS NOT NULL").size).to eq 2

      # The type-level probe and the load itself, however many rows come back.
      expect(capture_sql { document_class.find(@org1_doc.id) }.grep(/super_auth_authorizations/).size).to eq 2
      expect(capture_sql { document_class.all.to_a }.grep(/super_auth_authorizations/).size).to eq 2
      expect(document_class.all.map(&:id)).to match_array [@org1_doc.id, @orphan.id]
    end

    it "carries the OR into an instance's update, reload and destroy" do
      grant("Organization::Member", 1)

      statements = capture_sql do
        @org1_doc.update!(name: "renamed")
        @org1_doc.reload
        @org1_doc.destroy
      end
      %w[UPDATE SELECT DELETE].each do |verb|
        statement = statements.grep(/\A#{verb} .*#{Regexp.escape(quoted(:documents, :id))}/).first
        expect(statement).to include("#{quoted(:documents, :id)} IN (SELECT")
        expect(statement).to include("#{quoted(:documents, :organization_id)} IN (SELECT")
      end
      expect(document_class.unscoped.where(id: @org1_doc.id)).to be_empty
    end

    it "leaves a row the user does not reach untouched by instance writes" do
      grant("Organization::Member", 1)

      expect { @org2_doc.reload }.to raise_error(ActiveRecord::RecordNotFound)
      @org2_doc.update!(name: "renamed")
      @org2_doc.destroy
      expect(document_class.unscoped.find(@org2_doc.id).name).to eq "org2"
    end

    context "subclasses" do
      let(:writable_class) do
        Class.new(document_class) do
          def self.name = "Document::Writable"
        end
      end

      let(:case_writer_class) do
        Class.new(document_class) do
          def self.name = "Document::Writable"
          super_auth parent: { column: :organization_id, resource_type: "Organization::CaseWriter" }
        end
      end

      it "is keyed on its own name and inherits the parents" do
        grant("Organization::Member", 1)
        grant("Document", @orphan.id)

        expect(writable_class.super_auth_effective_reach).to eq(id: ["Document::Writable"], organization_id: ["Organization::Member", "Organization::Admin"])
        expect(writable_class.all.map(&:id)).to eq [@org1_doc.id]

        grant("Document::Writable", @orphan.id)
        expect(writable_class.all.map(&:id)).to match_array [@org1_doc.id, @orphan.id]
        expect(document_class.all.map(&:id)).to match_array [@org1_doc.id, @orphan.id]
      end

      it "re-declares its own parents without touching the base's or adding a scope" do
        expect(case_writer_class.super_auth_reach).to eq(id: ["Document::Writable"], organization_id: ["Organization::CaseWriter"])
        expect(document_class.super_auth_reach).to eq(id: ["Document"], organization_id: ["Organization::Member", "Organization::Admin"])
        expect(case_writer_class.default_scopes.size).to eq 1
        expect(document_class.default_scopes.size).to eq 1

        grant("Organization::Member", 1)
        expect(document_class.all.map(&:id)).to eq [@org1_doc.id]
        expect(case_writer_class.all.to_a).to be_empty

        grant("Organization::CaseWriter", 1)
        expect(case_writer_class.all.map(&:id)).to eq [@org1_doc.id]
      end

      it "explains through its own name" do
        grant("Document", @org1_doc.id)
        grant("Organization::CaseWriter", 1)

        expect(case_writer_class.super_auth_explain(@org1_doc).map { |row| row[:step] }).to eq [:organization_id]
        grant("Document::Writable", @org1_doc.id)
        expect(case_writer_class.super_auth_explain(@org1_doc).map { |row| row[:step] }).to eq [:id, :organization_id]
      end
    end

    context "wildcard: false" do
      let(:document_class) do
        Class.new(ActiveRecord::Base) do
          self.table_name = :documents
          def self.name = "Document"
          super_auth parent: { column: :organization_id, resource_type: "Organization::Member" }, wildcard: false
        end
      end

      it "drops the type-level step" do
        grant("Document", nil)
        grant("Organization::Member", 1)

        expect(document_class.super_auth_wildcard).to be false
        expect(capture_sql { document_class.all.to_a }.grep(/super_auth_authorizations/).size).to eq 1
        expect(document_class.all.map(&:id)).to eq [@org1_doc.id]
        expect(document_class.super_auth_explain(@org1_doc).map { |row| row[:step] }).to eq [:organization_id]
      end
    end

    context "preflight" do
      let(:missing_column_class) do
        Class.new(ActiveRecord::Base) do
          self.table_name = :documents
          def self.name = "Document"
          super_auth parent: { column: :folder_id, resource_type: "Folder" }
        end
      end

      let(:mistyped_class) do
        Class.new(ActiveRecord::Base) do
          self.table_name = :mistyped_documents
          def self.name = "MistypedDocument"
          super_auth parent: { column: :organization_id, resource_type: "Organization::Member" }
        end
      end

      it "reads no schema at declaration, so a process boots before its migrations" do
        expect(capture_sql { missing_column_class }).to be_empty
      end

      it "refuses a parent column the table does not have" do
        expect { missing_column_class.all.to_a }
          .to raise_error(SuperAuth::Error, "Document declares parent column folder_id, which table documents does not have")
      end

      it "refuses a parent column outside the external id type family" do
        expect { mistyped_class.all.to_a }.to raise_error(
          SuperAuth::Error,
          /\AMistypedDocument\.organization_id is (varchar|character varying)\(255\) but super_auth_authorizations\.resource_external_id is bigint/
        )
      end

      it "runs ahead of the type-level probe and not for the system user" do
        grant("MistypedDocument", nil)
        expect { mistyped_class.all.to_a }.to raise_error(SuperAuth::Error, /organization_id/)

        SuperAuth.current_user = SuperAuth::ActiveRecord::User.system
        expect(mistyped_class.count).to eq 0
      end
    end

    describe ".super_auth_explain" do
      it "tags each compiled row admitting the record with its step" do
        grant("Document", nil)
        grant("Document", @org1_doc.id)
        grant("Organization::Member", 1)
        grant("Organization::Admin", 2)

        rows = document_class.super_auth_explain(@org1_doc)
        expect(rows.map { |row| row[:step] }).to eq [:type_level, :id, :organization_id]
        expect(rows.map { |row| row.values_at(:resource_external_type, :resource_external_id) })
          .to eq [["Document", nil], ["Document", @org1_doc.id], ["Organization::Member", 1]]
        expect(rows.first.keys).to include(:step, :user_id, :resource_external_type, :resource_external_id)

        expect(document_class.super_auth_explain(@org2_doc.id).map { |row| row[:step] }).to eq [:type_level, :organization_id]
        expect(document_class.super_auth_explain(@orphan.id).map { |row| row[:step] }).to eq [:type_level]
      end

      it "answers for a row the user cannot see" do
        grant("Organization::Member", 1)

        expect(document_class.super_auth_explain(@org2_doc.id)).to eq []
        expect { document_class.super_auth_explain(-1) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "reports the system bypass and the missing user" do
        SuperAuth.current_user = SuperAuth::ActiveRecord::User.system
        expect(document_class.super_auth_explain(@org1_doc)).to eq [{ step: :system }]

        SuperAuth.current_user = nil
        expect(document_class.super_auth_explain(@org1_doc)).to eq []
        SuperAuth.missing_user_behavior = :raise
        expect { document_class.super_auth_explain(@org1_doc) }.to raise_error(SuperAuth::Error, "SuperAuth.current_user not set")
      ensure
        SuperAuth.missing_user_behavior = :none
      end
    end
  end
end
