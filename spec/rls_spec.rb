require "spec_helper"

# External-user class for apply_user (anonymous classes have no name).
SuperAuthRlsSpecUser = Struct.new(:id)
SuperAuthRlsSpecSystemUser = Struct.new(:id) do
  def system?
    true
  end
end

RSpec.describe SuperAuth::RLS do
  let(:db) { SuperAuth.db }

  # The CI/test connection is a superuser, which always bypasses RLS. Run the
  # actual assertions as a plain role so the policy applies.
  def as_restricted_role
    db.run "SET ROLE super_auth_rls_spec"
    yield
  ensure
    db.run "RESET ROLE"
  end

  def doc_names
    as_restricted_role { db[:documents].select_order_map(:name) }
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

    SuperAuth.install_migrations
    SuperAuth.load
    db.run "CREATE TABLE documents (id serial PRIMARY KEY, name text)"
    db.run "DO $$ BEGIN CREATE ROLE super_auth_rls_spec; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
    db.run "GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO super_auth_rls_spec"
    db.run "GRANT USAGE ON SEQUENCE documents_id_seq TO super_auth_rls_spec"
    db.run "GRANT SELECT ON super_auth_authorizations TO super_auth_rls_spec"
    described_class.enable(:documents, resource_type: "Document")

    example.run
  ensure
    if SuperAuth.db.database_type == :postgres
      SuperAuth.rls = false
      described_class.clear
      db.run "RESET ROLE"
      db.run "DROP TABLE IF EXISTS documents"
      db.run "DROP OWNED BY super_auth_rls_spec" # revoke grants so the role can drop
      db.run "DROP ROLE IF EXISTS super_auth_rls_spec"
      SuperAuth.uninstall_migrations
    end
  end

  let!(:doc1_id) { db[:documents].insert(name: "doc1") }
  let!(:doc2_id) { db[:documents].insert(name: "doc2") }

  it "hides all rows when no identity is set" do
    described_class.clear
    expect(doc_names).to eq([])
  end

  it "shows only rows the user is authorized for" do
    grant(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id.to_s)
    described_class.apply_user(SuperAuthRlsSpecUser.new(42))
    expect(doc_names).to eq(["doc1"])
  end

  it "treats a type-level authorization (resource_external_id NULL) as a wildcard" do
    grant(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser")
    described_class.apply_user(SuperAuthRlsSpecUser.new(42))
    expect(doc_names).to eq(["doc1", "doc2"])
  end

  it "does not leak rows to a different user of the same id but different type" do
    grant(user_external_id: "42", user_external_type: "SomeOtherClass", resource_external_id: doc1_id.to_s)
    described_class.apply_user(SuperAuthRlsSpecUser.new(42))
    expect(doc_names).to eq([])
  end

  it "matches internal SuperAuth users on user_id" do
    user = SuperAuth::User.create(name: "internal")
    grant(user_id: user.id, resource_external_id: doc2_id.to_s)
    described_class.apply_user(user)
    expect(doc_names).to eq(["doc2"])
  end

  it "bypasses the policy for system users" do
    described_class.apply_user(SuperAuthRlsSpecSystemUser.new(1))
    expect(doc_names).to eq(["doc1", "doc2"])
  end

  it "scopes UPDATE and DELETE to authorized rows" do
    grant(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id.to_s)
    described_class.apply_user(SuperAuthRlsSpecUser.new(42))
    as_restricted_role do
      expect(db[:documents].update(name: "renamed")).to eq(1)
      expect(db[:documents].delete).to eq(1)
    end
    described_class.apply_user(SuperAuthRlsSpecSystemUser.new(1))
    expect(doc_names).to eq(["doc2"])
  end

  it "blocks INSERT without an authorization" do
    described_class.clear
    expect {
      as_restricted_role { db[:documents].insert(name: "doc3") }
    }.to raise_error(Sequel::DatabaseError, /row-level security/)
  end

  it "allows INSERT (with RETURNING) under a type-level authorization" do
    grant(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser")
    described_class.apply_user(SuperAuthRlsSpecUser.new(42))
    id = as_restricted_role { db[:documents].insert(name: "doc3") }
    expect(id).to be_a(Integer)
    expect(doc_names).to eq(["doc1", "doc2", "doc3"])
  end

  it "restores full visibility after disable" do
    described_class.clear
    described_class.disable(:documents)
    expect(doc_names).to eq(["doc1", "doc2"])
  end

  it "is idempotent" do
    expect { described_class.enable(:documents, resource_type: "Document") }.not_to raise_error
  end

  describe "SuperAuth.current_user= integration" do
    it "mirrors identity into session settings when SuperAuth.rls is on" do
      grant(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id.to_s)
      SuperAuth.rls = true
      SuperAuth.current_user = SuperAuthRlsSpecUser.new(42)
      expect(doc_names).to eq(["doc1"])
      SuperAuth.current_user = nil
      expect(doc_names).to eq([])
    end

    it "does not touch the database when SuperAuth.rls is off" do
      expect(described_class).not_to receive(:apply_user)
      SuperAuth.current_user = SuperAuthRlsSpecUser.new(42)
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
