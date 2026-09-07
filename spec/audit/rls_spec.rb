require "spec_helper"

# Findings from the September 2026 test audit, pinned as specs. See
# spec/audit/graph_spec.rb for the pending/tripwire convention and
# ~/.claude/plans/superauth-audit-fix-handoff.md for the full context (C1, C2,
# ... match the tags in the titles).
#
# Everything under the first describe is Postgres only, like spec/rls_spec.rb.
# The last describe runs on every adapter.

AuditRlsUser = Struct.new(:id)

RSpec.describe "Audit: row-level security" do
  let(:db) { SuperAuth.db }

  # Same role plumbing as spec/rls_spec.rb: the test connection is a superuser,
  # which RLS ignores and which the identity functions refuse, so everything
  # under test runs as the application role. Nested calls keep the role; only
  # the outermost call resets, which keeps RESET ROLE out of a transaction
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

  # What the superuser test connection sees: everything.
  def all_doc_names
    db[:documents].select_order_map(:name)
  end

  def become(user_external_id: nil, user_external_type: nil, user_id: nil)
    as_restricted_role do
      db.transaction do
        db.get(Sequel.function(:super_auth_become, user_external_id, user_external_type, user_id))
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
    skip "Postgres only" unless db.database_type == :postgres

    SuperAuth.external_id_type = example.metadata[:external_id_type] || :bigint
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    SuperAuth.install_migrations
    SuperAuth.load
    SuperAuth.refresh_model_schemas
    db.run "CREATE TABLE documents (id serial PRIMARY KEY, name text)"
    # Privileges on the application table only; enable grants the rest.
    db.run "DO $$ BEGIN CREATE ROLE super_auth_rls_spec; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
    db.run "GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO super_auth_rls_spec"
    db.run "GRANT USAGE ON SEQUENCE documents_id_seq TO super_auth_rls_spec"
    SuperAuth::RLS.enable(:documents, resource_type: "Document") unless example.metadata[:skip_enable]

    example.run
  ensure
    if db.database_type == :postgres
      SuperAuth.external_id_type = :string
      db.run "RESET ROLE"
      db.run "DROP TABLE IF EXISTS documents"
      db.run "DROP OWNED BY super_auth_rls_spec"
      db.run "DROP ROLE IF EXISTS super_auth_rls_spec"
      SuperAuth.uninstall_migrations
      SuperAuth.refresh_model_schemas
    end
  end

  let!(:doc1_id) { db[:documents].insert(name: "doc1") }
  let!(:doc2_id) { db[:documents].insert(name: "doc2") }

  describe "C1: nested SuperAuth.as" do
    # Fixed 2026-09-07: RLS.as reads the enclosing identity when nested and
    # puts it back on exit. Kept as a tripwire.
    it "C1: restores the outer identity after a nested SuperAuth.as returns" do
      grant(user_external_id: 1, user_external_type: "AuditRlsUser", resource_external_id: doc1_id)
      grant(user_external_id: 2, user_external_type: "AuditRlsUser", resource_external_id: doc2_id)

      names = as_restricted_role do
        SuperAuth.as(AuditRlsUser.new(1)) do
          SuperAuth.as(AuditRlsUser.new(2)) {}
          doc_names
        end
      end
      expect(names).to eq ["doc1"]
    end
  end

  describe "C2: who may assert system context" do
    # Fixed 2026-09-06: the system bypass moved from a parameter of
    # super_auth_become() to super_auth_system(), whose EXECUTE is revoked from
    # PUBLIC by enable. spec/rls_spec.rb covers the grant path; this pins the
    # deny path for a role that can assert user identities but was not granted
    # the bypass.
    it "C2: the application role cannot assert system context" do
      expect {
        as_restricted_role { db.transaction { db.get(Sequel.function(:super_auth_system)) } }
      }.to raise_error(Sequel::DatabaseError, /permission denied for function super_auth_system/)
      expect(all_doc_names).to eq ["doc1", "doc2"]
    end
  end

  describe "C3: identity edge cases" do
    it "C3: SuperAuth.as(nil) sees nothing" do
      grant(user_external_id: 1, user_external_type: "AuditRlsUser")
      expect(as_restricted_role { SuperAuth.as(nil) { doc_names } }).to eq []
    end

    it "C3: SuperAuth.as with a SuperAuth::ActiveRecord::User matches on user_id" do
      user = SuperAuth::ActiveRecord::User.create!(name: "ar")
      grant(user_id: user.id, resource_external_id: doc2_id)
      expect(as_restricted_role { SuperAuth.as(user) { doc_names } }).to eq ["doc2"]
    end

    it "C3: a per-record identity cannot INSERT" do
      grant(user_external_id: 1, user_external_type: "AuditRlsUser", resource_external_id: doc1_id)
      expect {
        become(user_external_id: "1", user_external_type: "AuditRlsUser") { db[:documents].insert(name: "doc3") }
      }.to raise_error(Sequel::DatabaseError, /row-level security/)
      expect(all_doc_names).to eq ["doc1", "doc2"]
    end
  end

  describe "C4: enable with external id columns that do not match the table's key", external_id_type: :string, skip_enable: true do
    it "C4: raises a SuperAuth::Error that names external_id_type" do
      pending "C4: CREATE POLICY fails with a raw Postgres error (integer = character varying) instead"
      expect {
        SuperAuth::RLS.enable(:documents, resource_type: "Document")
      }.to raise_error(SuperAuth::Error, /external_id_type/)
    end
  end
end

RSpec.describe "Audit: SuperAuth::RLS.enable on a non-Postgres database" do
  # C5: spec/rls_spec.rb has this check, but inside its Postgres-only around, so
  # it is skipped exactly where it matters. This one runs everywhere.
  it "C5: raises SuperAuth::Error" do
    # Sequel models bind to the first Sequel::Database created in the process,
    # so the real connection must exist before this throwaway one.
    SuperAuth.db
    sqlite = Sequel.sqlite
    expect {
      SuperAuth::RLS.enable(:documents, resource_type: "Document", db: sqlite)
    }.to raise_error(SuperAuth::Error, /requires Postgres/)
  end
end
