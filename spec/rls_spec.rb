require "spec_helper"

# External-user class for SuperAuth.as (anonymous classes have no name).
SuperAuthRlsSpecUser = Struct.new(:id)
SuperAuthRlsSpecSystemUser = Struct.new(:id) do
  def system?
    true
  end
end

RSpec.describe SuperAuth::RLS do
  let(:db) { SuperAuth.db }

  # The CI/test connection is a superuser, which always bypasses RLS, and
  # both identity functions refuse a superuser caller. So every assertion and
  # every query under test runs as a plain role: super_auth_rls_spec is the
  # application role, super_auth_rls_spec_system additionally holds EXECUTE
  # on super_auth_system(). Nested calls keep the outer role; only the
  # outermost call resets, which also keeps RESET ROLE out of a transaction
  # that a failing statement has already aborted.
  def as_restricted_role(role = :super_auth_rls_spec)
    @role_depth = (@role_depth || 0) + 1
    db.run "SET ROLE #{role}" if @role_depth == 1
    yield
  ensure
    @role_depth -= 1
    db.run "RESET ROLE" if @role_depth.zero?
  end

  def doc_names
    as_restricted_role { db[:documents].select_order_map(:name) }
  end

  # What the superuser test connection sees: everything, RLS does not apply.
  def all_doc_names
    db[:documents].select_order_map(:name)
  end

  # The SQL contract any client follows, as the application role:
  # BEGIN; SELECT super_auth_become(...); queries; COMMIT.
  def become(user_external_id: nil, user_external_type: nil, user_id: nil)
    as_restricted_role do
      db.transaction do
        db.get(Sequel.function(:super_auth_become, user_external_id, user_external_type, user_id))
        yield
      end
    end
  end

  # The bypass contract, as a role that was granted EXECUTE on super_auth_system():
  # BEGIN; SELECT super_auth_system(); queries; COMMIT.
  def become_system
    as_restricted_role(:super_auth_rls_spec_system) do
      db.transaction do
        db.get(Sequel.function(:super_auth_system))
        yield
      end
    end
  end

  def grant(user_external_id: nil, user_external_type: nil, user_id: nil, resource_external_id: nil)
    db[:super_auth_authorizations].insert(
      user_id: user_id,
      user_external_id: user_external_id,
      user_external_type: user_external_type,
      resource_external_type: "Document",
      resource_external_id: resource_external_id,
    )
  end

  around do |example|
    skip "Postgres only" unless SuperAuth.db.database_type == :postgres

    # documents uses an integer pk, so install with matching external id
    # columns — the typed policy comparison depends on it. Reinstall in case
    # an earlier spec group left tables with the default :string columns
    # (install_migrations is a no-op when tables exist).
    SuperAuth.external_id_type = :bigint
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    SuperAuth.install_migrations
    SuperAuth.load
    db.run "CREATE TABLE documents (id serial PRIMARY KEY, name text)"
    # The roles get privileges on the application table only; everything
    # they need on the gem's own tables comes from enable.
    %w[super_auth_rls_spec super_auth_rls_spec_system].each do |role|
      db.run "DO $$ BEGIN CREATE ROLE #{role}; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
      db.run "GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO #{role}"
      db.run "GRANT USAGE ON SEQUENCE documents_id_seq TO #{role}"
    end
    described_class.enable(:documents, resource_type: "Document")
    described_class.grant_system(:super_auth_rls_spec_system)

    example.run
  ensure
    if SuperAuth.db.database_type == :postgres
      SuperAuth.external_id_type = :string
      db.run "RESET ROLE"
      db.run "DROP TABLE IF EXISTS documents"
      %w[super_auth_rls_spec super_auth_rls_spec_system].each do |role|
        db.run "DROP OWNED BY #{role}" # revoke grants so the role can drop
        db.run "DROP ROLE IF EXISTS #{role}"
      end
      SuperAuth.uninstall_migrations
    end
  end

  let!(:doc1_id) { db[:documents].insert(name: "doc1") }
  let!(:doc2_id) { db[:documents].insert(name: "doc2") }

  it "hides all rows without an identity assertion" do
    expect(doc_names).to eq([])
  end

  it "shows granted rows inside the asserting transaction and none after it" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
    names = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") { doc_names }
    expect(names).to eq(["doc1"])
    expect(doc_names).to eq([]) # identity died with the transaction
  end

  it "ignores session-scoped identity from a previous transaction (the leak path)" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
    settings = {
      "super_auth.user_id" => "",
      "super_auth.user_external_id" => "42",
      "super_auth.user_external_type" => "SuperAuthRlsSpecUser",
      "super_auth.system" => "",
    }
    db.transaction do
      settings.each { |name, value| db.get(Sequel.function(:set_config, name, value, false)) }
      db.get(Sequel.function(:set_config, "super_auth.xid", Sequel.function(:pg_current_xact_id).cast(:text), false))
    end
    # The stamp belongs to a committed transaction, so it can never match
    # pg_current_xact_id() again: leaked session identity grants nothing.
    expect(doc_names).to eq([])
  ensure
    if SuperAuth.db.database_type == :postgres
      (settings.keys + ["super_auth.xid"]).each do |name|
        db.get(Sequel.function(:set_config, name, "", false))
      end
    end
  end

  it "treats a type-level authorization (resource_external_id NULL) as a wildcard" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
    names = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") { doc_names }
    expect(names).to eq(["doc1", "doc2"])
  end

  it "does not leak rows to a different user of the same id but different type" do
    grant(user_external_id: 42, user_external_type: "SomeOtherClass", resource_external_id: doc1_id)
    names = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") { doc_names }
    expect(names).to eq([])
  end

  it "matches internal SuperAuth users on user_id" do
    user = SuperAuth::User.create(name: "internal")
    grant(user_id: user.id, resource_external_id: doc2_id)
    names = become(user_id: user.id.to_s) { doc_names }
    expect(names).to eq(["doc2"])
  end

  it "bypasses the policy for system context asserted through super_auth_system()" do
    names = become_system { doc_names }
    expect(names).to eq(["doc1", "doc2"])
    expect(doc_names).to eq([]) # system context died with the transaction too
  end

  it "does not let the application role call super_auth_system()" do
    expect {
      as_restricted_role do
        db.transaction { db.get(Sequel.function(:super_auth_system)) }
      end
    }.to raise_error(Sequel::DatabaseError, /permission denied for function super_auth_system/)
  end

  it "no longer accepts a system flag on super_auth_become()" do
    expect {
      as_restricted_role do
        db.transaction { db.get(Sequel.function(:super_auth_become, nil, nil, nil, true)) }
      end
    }.to raise_error(Sequel::DatabaseError, /function super_auth_become\(unknown, unknown, unknown, boolean\) does not exist/)
  end

  it "replaces system context with a user identity when super_auth_become() follows super_auth_system()" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
    names = become_system do
      db.get(Sequel.function(:super_auth_become, "42", "SuperAuthRlsSpecUser", nil))
      doc_names
    end
    expect(names).to eq(["doc1"])
  end

  describe "superuser callers" do
    # The test connection is a superuser. Neither function may pretend to
    # protect it.
    it "refuses super_auth_become()" do
      expect {
        db.transaction { db.get(Sequel.function(:super_auth_become, "42", "SuperAuthRlsSpecUser", nil)) }
      }.to raise_error(Sequel::DatabaseError, /superuser or has BYPASSRLS/)
    end

    it "refuses super_auth_system()" do
      expect {
        db.transaction { db.get(Sequel.function(:super_auth_system)) }
      }.to raise_error(Sequel::DatabaseError, /superuser or has BYPASSRLS/)
    end

    it "refuses SuperAuth.as" do
      expect {
        SuperAuth.as(SuperAuthRlsSpecUser.new(42)) {}
      }.to raise_error(Sequel::DatabaseError, /superuser or has BYPASSRLS/)
    end

    it "refuses a BYPASSRLS role even when it is not a superuser" do
      db.run "DO $$ BEGIN CREATE ROLE super_auth_rls_spec_bypass BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
      expect {
        as_restricted_role(:super_auth_rls_spec_bypass) do
          db.transaction { db.get(Sequel.function(:super_auth_become, "42", "SuperAuthRlsSpecUser", nil)) }
        end
      }.to raise_error(Sequel::DatabaseError, /superuser or has BYPASSRLS/)
    ensure
      db.run "RESET ROLE"
      db.run "DROP ROLE IF EXISTS super_auth_rls_spec_bypass"
    end
  end

  it "scopes UPDATE and DELETE to authorized rows" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
    become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
      expect(db[:documents].update(name: "renamed")).to eq(1)
      expect(db[:documents].delete).to eq(1)
    end
    expect(all_doc_names).to eq(["doc2"])
  end

  it "blocks INSERT without an identity assertion" do
    expect {
      as_restricted_role { db[:documents].insert(name: "doc3") }
    }.to raise_error(Sequel::DatabaseError, /row-level security/)
  end

  it "allows INSERT (with RETURNING) under a type-level authorization" do
    grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
    become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
      id = db[:documents].insert(name: "doc3")
      expect(id).to be_a(Integer)
      expect(doc_names).to eq(["doc1", "doc2", "doc3"])
    end
  end

  # `DELETE FROM documents` with no WHERE clause — what a buggy script, a
  # client that can assert user identities but not system context, or
  # `Model.unscoped.delete_all` would issue. The policy must scope it to rows
  # the asserted identity can see, and to nothing at all when no identity was
  # asserted in the current transaction.
  describe "unfiltered DELETE" do
    def surviving_docs
      all_doc_names
    end

    it "deletes nothing without an identity assertion" do
      expect(as_restricted_role { db[:documents].delete }).to eq(0)
      expect(surviving_docs).to eq(["doc1", "doc2"])
    end

    it "deletes nothing after the asserting transaction has committed" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
      become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") {}
      expect(as_restricted_role { db[:documents].delete }).to eq(0)
      expect(surviving_docs).to eq(["doc1", "doc2"])
    end

    it "deletes nothing under session-scoped identity leaked from a previous transaction" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
      settings = {
        "super_auth.user_id" => "",
        "super_auth.user_external_id" => "42",
        "super_auth.user_external_type" => "SuperAuthRlsSpecUser",
        "super_auth.system" => "",
      }
      db.transaction do
        settings.each { |name, value| db.get(Sequel.function(:set_config, name, value, false)) }
        db.get(Sequel.function(:set_config, "super_auth.xid", Sequel.function(:pg_current_xact_id).cast(:text), false))
      end
      expect(as_restricted_role { db[:documents].delete }).to eq(0)
      expect(surviving_docs).to eq(["doc1", "doc2"])
    ensure
      if settings && SuperAuth.db.database_type == :postgres
        (settings.keys + ["super_auth.xid"]).each do |name|
          db.get(Sequel.function(:set_config, name, "", false))
        end
      end
    end

    it "deletes nothing for an identity granted only under a different user type" do
      grant(user_external_id: 42, user_external_type: "SomeOtherClass")
      deleted = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
        as_restricted_role { db[:documents].delete }
      end
      expect(deleted).to eq(0)
      expect(surviving_docs).to eq(["doc1", "doc2"])
    end

    it "deletes only the granted row under a per-record authorization" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
      deleted = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
        db[:documents].delete
      end
      expect(deleted).to eq(1)
      expect(surviving_docs).to eq(["doc2"])
    end

    it "returns only the granted row from DELETE ... RETURNING" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
      rows = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
        db[:documents].returning(:name).delete
      end
      expect(rows).to eq([{ name: "doc1" }])
      expect(surviving_docs).to eq(["doc2"])
    end

    it "scopes a DELETE smuggled through a data-modifying CTE" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
      deleted = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
        db.fetch("WITH gone AS (DELETE FROM documents RETURNING name) SELECT name FROM gone").map(:name)
      end
      expect(deleted).to eq(["doc1"])
      expect(surviving_docs).to eq(["doc2"])
    end

    it "scopes ActiveRecord unscoped.delete_all the same way" do
      skip "requires the sequel-activerecord_connection bridge" unless db.respond_to?(:activerecord_model)
      document_model = Class.new(::ActiveRecord::Base) { self.table_name = "documents" }
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
      deleted = as_restricted_role do
        SuperAuth.as(SuperAuthRlsSpecUser.new(42)) { document_model.unscoped.delete_all }
      end
      expect(deleted).to eq(1)
      expect(surviving_docs).to eq(["doc2"])
    end

    it "lets a type-level wildcard delete every row" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser")
      deleted = become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser") do
        db[:documents].delete
      end
      expect(deleted).to eq(2)
      expect(surviving_docs).to eq([])
    end

    it "lets system context delete every row" do
      expect(become_system { db[:documents].delete }).to eq(2)
      expect(surviving_docs).to eq([])
    end

    it "cannot be escalated to TRUNCATE, which RLS does not police" do
      # Privileges are checked before RLS, so no asserted identity changes
      # this: safety rests on the grant set withholding TRUNCATE.
      expect {
        as_restricted_role { db.run "TRUNCATE documents" }
      }.to raise_error(Sequel::DatabaseError, /permission denied/)
      expect(surviving_docs).to eq(["doc1", "doc2"])
    end
  end

  it "restores full visibility after disable" do
    described_class.disable(:documents)
    expect(doc_names).to eq(["doc1", "doc2"])
  end

  it "is idempotent" do
    expect { described_class.enable(:documents, resource_type: "Document") }.not_to raise_error
  end

  it "grants every role what it needs on the gem's own tables" do
    # The spec roles were granted nothing on super_auth_* tables; enable did it.
    as_restricted_role do
      expect(db[:super_auth_authorizations].count).to eq(0)
      expect(db[:super_auth_users].count).to eq(0)
    end
  end

  it "asserts identity for a SuperAuth user record without the system row existing" do
    user = SuperAuth::User.create(name: "internal")
    grant(user_id: user.id, resource_external_id: doc2_id)
    expect(db[:super_auth_users].where(name: "system").count).to eq(0)
    expect(as_restricted_role { SuperAuth.as(user) { doc_names } }).to eq(["doc2"])
    expect(db[:super_auth_users].where(name: "system").count).to eq(0) # system? never creates it
  end

  describe "SuperAuth.as" do
    it "asserts an external user's identity for the block" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
      names = as_restricted_role { SuperAuth.as(SuperAuthRlsSpecUser.new(42)) { doc_names } }
      expect(names).to eq(["doc1"])
      expect(doc_names).to eq([])
    end

    it "matches internal SuperAuth users on user_id" do
      user = SuperAuth::User.create(name: "internal")
      grant(user_id: user.id, resource_external_id: doc2_id)
      expect(as_restricted_role { SuperAuth.as(user) { doc_names } }).to eq(["doc2"])
    end

    it "asserts system context for system users through super_auth_system()" do
      names = as_restricted_role(:super_auth_rls_spec_system) do
        SuperAuth.as(SuperAuthRlsSpecSystemUser.new(1)) { doc_names }
      end
      expect(names).to eq(["doc1", "doc2"])
    end

    it "fails for a system user when the role was not granted super_auth_system()" do
      expect {
        as_restricted_role { SuperAuth.as(SuperAuthRlsSpecSystemUser.new(1)) {} }
      }.to raise_error(Sequel::DatabaseError, /permission denied for function super_auth_system/)
    end
  end

  describe ".enable on a non-Postgres database" do
    it "raises SuperAuth::Error" do
      sqlite = Sequel.sqlite
      expect {
        described_class.enable(:documents, resource_type: "Document", db: sqlite)
      }.to raise_error(SuperAuth::Error, /requires Postgres/)
    end
  end
end
