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

  def grant(user_external_id: nil, user_external_type: nil, user_id: nil, resource_external_id: nil, resource_external_type: "Document")
    db[:super_auth_authorizations].insert(
      user_id: user_id,
      user_external_id: user_external_id,
      user_external_type: user_external_type,
      resource_external_type: resource_external_type,
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
    # Other spec files build a documents table of their own shape and may
    # leave it behind; this one needs the shape below.
    db.run "DROP TABLE IF EXISTS documents"
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

  # A grant on a container reaches the records registered under it, and each
  # compiled row keeps the descendant's own type and id, so the policy sees
  # per-record rows and nothing wider. The container's own row has no type,
  # which the policy matches against nothing.
  describe "container grants" do
    let(:user) { SuperAuth::User.create(name: "member") }

    def register(name, id, under:)
      SuperAuth::Resource.create(name: name, external_type: "Document", external_id: id, parent: under)
    end

    it "shows exactly the records registered under the container" do
      folder = SuperAuth::Resource.create(name: "folder")
      register("doc1", doc1_id, under: folder)
      register("doc2", doc2_id, under: folder)
      db[:documents].insert(name: "doc3") # never registered
      SuperAuth::Edge.create(user: user, resource: folder)
      expect(SuperAuth::Authorization.compile!).to eq(3)

      expect(become(user_id: user.id.to_s) { doc_names }).to eq(["doc1", "doc2"])
    end

    it "grants nothing through the container's own row" do
      folder = SuperAuth::Resource.create(name: "folder")
      SuperAuth::Edge.create(user: user, resource: folder)
      expect(SuperAuth::Authorization.compile!).to eq(1)
      expect(db[:super_auth_authorizations].select_map([:resource_id, :resource_external_type, :resource_external_id])).to eq([[folder.id, nil, nil]])

      expect(become(user_id: user.id.to_s) { doc_names }).to eq([])
    end

    # Unlike a type-level wildcard, a container grant is per record, so it
    # authorizes no INSERT: WITH CHECK reuses USING, and a row that does not
    # exist yet has no authorization row to match.
    it "is per-record: INSERT under the identity is still refused" do
      folder = SuperAuth::Resource.create(name: "folder")
      register("doc1", doc1_id, under: folder)
      register("doc2", doc2_id, under: folder)
      SuperAuth::Edge.create(user: user, resource: folder)
      SuperAuth::Authorization.compile!

      expect {
        become(user_id: user.id.to_s) { db[:documents].insert(name: "doc3") }
      }.to raise_error(Sequel::DatabaseError, /row-level security/)
      expect(all_doc_names).to eq(["doc1", "doc2"])
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

    describe "both identities" do
      before { SuperAuth.current_user = nil } # other spec files leave a user behind
      after { SuperAuth.current_user = nil }

      it "sets SuperAuth.current_user for the block and restores the previous value after it" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        outer = SuperAuthRlsSpecUser.new(7)
        SuperAuth.current_user = outer
        inside = nil

        names = as_restricted_role do
          SuperAuth.as(SuperAuthRlsSpecUser.new(42)) do
            inside = SuperAuth.current_user
            doc_names
          end
        end

        expect(inside.id).to eq(42)
        expect(names).to eq(["doc1"])
        expect(SuperAuth.current_user).to equal(outer)
      end

      it "assigns SuperAuth.current_user inside the transaction, after the database identity" do
        user = SuperAuthRlsSpecUser.new(42)
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        seen = nil
        allow(SuperAuth).to receive(:current_user=).and_wrap_original do |writer, value|
          seen = [db.in_transaction?, doc_names] if value.equal?(user)
          writer.call(value)
        end

        as_restricted_role { SuperAuth.as(user) {} }

        expect(seen).to eq([true, ["doc1"]])
      end

      it "restores both after the block raises" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        outer = SuperAuthRlsSpecUser.new(7)
        SuperAuth.current_user = outer

        expect {
          as_restricted_role { SuperAuth.as(SuperAuthRlsSpecUser.new(42)) { raise "boom" } }
        }.to raise_error(RuntimeError, "boom")

        expect(SuperAuth.current_user).to equal(outer)
        expect(doc_names).to eq([])
      end

      it "nests: the inner identity wins inside and the outer one is back afterwards" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        grant(user_external_id: 43, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc2_id)
        inner = outer = nil

        as_restricted_role do
          SuperAuth.as(SuperAuthRlsSpecUser.new(42)) do
            SuperAuth.as(SuperAuthRlsSpecUser.new(43)) do
              inner = [doc_names, SuperAuth.current_user.id]
            end
            outer = [doc_names, SuperAuth.current_user.id]
          end
        end

        expect(inner).to eq([["doc2"], 43])
        expect(outer).to eq([["doc1"], 42])
        expect(SuperAuth.current_user).to be_nil
      end

      it "restores the outer identity when the nested block raises" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        grant(user_external_id: 43, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc2_id)

        outer = as_restricted_role do
          SuperAuth.as(SuperAuthRlsSpecUser.new(42)) do
            begin
              SuperAuth.as(SuperAuthRlsSpecUser.new(43)) { raise "inner" }
            rescue RuntimeError
            end
            [doc_names, SuperAuth.current_user.id]
          end
        end

        expect(outer).to eq([["doc1"], 42])
      end

      it "asserts system context in both layers" do
        inside = as_restricted_role(:super_auth_rls_spec_system) do
          SuperAuth.as(SuperAuthRlsSpecSystemUser.new(1)) { [doc_names, SuperAuth.current_user.system?] }
        end
        expect(inside).to eq([["doc1", "doc2"], true])
        expect(SuperAuth.current_user).to be_nil
      end

      it "runs the block with no user in either layer for nil, then restores" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)
        SuperAuth.current_user = SuperAuthRlsSpecUser.new(42)

        inside = as_restricted_role { SuperAuth.as(nil) { [doc_names, SuperAuth.current_user] } }

        expect(inside).to eq([[], nil])
        expect(SuperAuth.current_user.id).to eq(42)
      end

      describe "transaction options" do
        let(:user) { SuperAuthRlsSpecUser.new(42) }

        before { grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser") } # type-level: may INSERT

        it "makes nested transactions savepoints with auto_savepoint: true" do
          as_restricted_role do
            SuperAuth.as(user, auto_savepoint: true) do
              db.transaction do
                db[:documents].insert(name: "doc3")
                raise Sequel::Rollback
              end
              db[:documents].insert(name: "doc4")
            end
          end
          expect(all_doc_names).to eq(["doc1", "doc2", "doc4"])
        end

        it "joins nested transactions by default, so a nested rollback rolls back the whole block" do
          as_restricted_role do
            SuperAuth.as(user) do
              db.transaction do
                db[:documents].insert(name: "doc3")
                raise Sequel::Rollback
              end
              db[:documents].insert(name: "doc4")
            end
          end
          expect(all_doc_names).to eq(["doc1", "doc2"])
        end

        it "fires ActiveRecord after_commit per save inside the block with auto_savepoint: true, and only after it otherwise" do
          skip "requires the sequel-activerecord_connection bridge" unless db.respond_to?(:activerecord_model)
          fired = []
          document_model = Class.new(::ActiveRecord::Base) { self.table_name = "documents" }
          document_model.after_commit { |record| fired << record.name }

          inside = nil
          as_restricted_role do
            SuperAuth.as(user, auto_savepoint: true) do
              document_model.create!(name: "doc3")
              inside = fired.dup
            end
          end
          expect(inside).to eq(["doc3"])

          fired.clear
          as_restricted_role do
            SuperAuth.as(user) do
              document_model.create!(name: "doc4")
              inside = fired.dup
            end
          end
          expect(inside).to eq([])
          expect(fired).to eq(["doc4"])
          expect(all_doc_names).to eq(["doc1", "doc2", "doc3", "doc4"])
        end

        it "rolls back what the block wrote before it raised" do
          expect {
            as_restricted_role do
              SuperAuth.as(user) do
                db[:documents].insert(name: "doc3")
                raise "after the write"
              end
            end
          }.to raise_error(RuntimeError, "after the write")
          expect(all_doc_names).to eq(["doc1", "doc2"])
        end

        it "leaves keeping a write that preceded a raise to the caller: rescue inside the block" do
          error = nil
          as_restricted_role do
            SuperAuth.as(user) do
              db[:documents].insert(name: "doc3")
              raise "after the write"
            rescue RuntimeError => e
              error = e
            end
          end
          expect(error.message).to eq("after the write")
          expect(all_doc_names).to eq(["doc1", "doc2", "doc3"])
        end
      end

      it "joins an enclosing transaction and leaves commit or rollback to it" do
        grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser") # type-level: may INSERT
        as_restricted_role do
          db.transaction do
            begin
              SuperAuth.as(SuperAuthRlsSpecUser.new(42)) do
                db[:documents].insert(name: "doc3")
                raise "after the write"
              end
            rescue RuntimeError
              # the caller chose to commit anyway
            end
          end
        end

        expect(all_doc_names).to eq(["doc1", "doc2", "doc3"])
      end
    end
  end

  describe ".assert" do
    let(:user) { SuperAuthRlsSpecUser.new(42) }

    before { grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id) }

    it "asserts the identity for the rest of the caller's transaction" do
      names = as_restricted_role do
        db.transaction do
          described_class.assert(user)
          doc_names
        end
      end
      expect(names).to eq(["doc1"])
      expect(doc_names).to eq([])
    end

    it "protects nothing outside a transaction: the identity dies with its statement" do
      as_restricted_role { described_class.assert(user) }
      expect(doc_names).to eq([])
    end

    it "re-asserts mid-transaction, replacing the identity SuperAuth.as put there" do
      grant(user_external_id: 43, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc2_id)
      names = as_restricted_role do
        SuperAuth.as(user) do
          described_class.assert(SuperAuthRlsSpecUser.new(43))
          doc_names
        end
      end
      expect(names).to eq(["doc2"])
    end

    it "matches internal SuperAuth users on user_id" do
      internal = SuperAuth::User.create(name: "internal")
      grant(user_id: internal.id, resource_external_id: doc2_id)
      names = as_restricted_role do
        db.transaction do
          described_class.assert(internal)
          doc_names
        end
      end
      expect(names).to eq(["doc2"])
    end

    it "asserts system context for a system user" do
      names = as_restricted_role(:super_auth_rls_spec_system) do
        db.transaction do
          described_class.assert(SuperAuthRlsSpecSystemUser.new(1))
          doc_names
        end
      end
      expect(names).to eq(["doc1", "doc2"])
    end

    it "fails for a system user when the role was not granted super_auth_system()" do
      expect {
        as_restricted_role { db.transaction { described_class.assert(SuperAuthRlsSpecSystemUser.new(1)) } }
      }.to raise_error(Sequel::DatabaseError, /permission denied for function super_auth_system/)
    end
  end

  describe ".installed?" do
    it "is true once enable has run" do
      expect(described_class.installed?).to be(true)
    end

    it "is false on a database that never ran enable" do
      db.run "DROP FUNCTION super_auth_become(text, text, text)"
      db.run "DROP FUNCTION super_auth_system()"
      expect(described_class.installed?).to be(false)
    end

    it "is false on a non-Postgres database" do
      expect(described_class.installed?(db: Sequel.sqlite)).to be(false)
    end
  end

  # What the catalogue holds for the documents table, read as the superuser.
  def policy_rows
    db.fetch(<<~SQL).all
      SELECT p.polname AS name, obj_description(p.oid, 'pg_policy') AS comment, pg_get_expr(p.polqual, p.polrelid) AS qual
      FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
      WHERE c.relname = 'documents' ORDER BY 1
    SQL
  end

  def policy_qual
    policy_rows.find { |row| row[:name] == "super_auth" }&.fetch(:qual)
  end

  def row_security
    db.fetch("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'documents'").first
  end

  # The policy 0.8.0 wrote: one EXISTS correlated on `IS NULL OR = documents.id`.
  def v1_policy_sql
    <<~SQL
      CREATE POLICY super_auth ON documents
      USING (
        current_setting('super_auth.xid', true) = pg_current_xact_id()::text
        AND (
          COALESCE(current_setting('super_auth.system', true), '') = 'true'
          OR EXISTS (
            SELECT 1 FROM super_auth_authorizations a
            WHERE a.resource_external_type = 'Document'
              AND (a.resource_external_id IS NULL OR a.resource_external_id = documents.id)
              AND (
                a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')
                OR (
                  a.user_external_id::text = NULLIF(current_setting('super_auth.user_external_id', true), '')
                  AND a.user_external_type = NULLIF(current_setting('super_auth.user_external_type', true), '')
                )
              )
          )
        )
      )
    SQL
  end

  # The identity halves are the one clause every step carries, so how they
  # compare a free-text setting against a typed column decides both what a
  # malformed identity does and what any of it can index.
  describe "the identity halves" do
    # Sequel logs every statement it runs, which is where the policy text is
    # visible as emitted rather than as Postgres prints it back.
    def emitted_sql
      recorder = Object.new
      recorder.define_singleton_method(:statements) { @statements ||= [] }
      %i[info error].each { |level| recorder.define_singleton_method(level) { |message| statements << message } }
      db.loggers << recorder
      yield
      recorder.statements
    ensure
      db.loggers.delete(recorder)
    end

    # The column is cast to text; the setting is never cast to a column type.
    # The comment above INTERNAL_USER says what casting the setting costs —
    # a transaction-wide abort on a malformed identity, and silent truncation
    # to varchar(255) on the default install. This example is what stops the
    # cast being reintroduced by someone re-deriving the index argument
    # without the safety one.
    it "casts the column, never the setting" do
      policy = emitted_sql { described_class.enable(:documents, resource_type: "Document") }
        .grep(/CREATE POLICY/).first

      expect(policy).to include("a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')")
      expect(policy).to include("a.user_external_id::text = NULLIF(current_setting('super_auth.user_external_id', true), '')")
      %w[uuid int integer bigint varchar].each do |type|
        expect(policy).not_to include("'')::#{type}")
      end
    end

    # super_auth_become validates nothing and become_args hands it
    # `user.id.to_s` for any object at all, so an id of the wrong type for the
    # install's columns is a reachable identity: 'abc' for the integer user_id
    # here, and '42' for user_external_id on a uuid install. Under the shipped
    # cast both are simply no rows. Under a cast on the setting the first
    # statement raises 22P02 and every later one in the transaction 25P02,
    # which is why the last assertion inside the transaction is the
    # load-bearing one: "denied" and "the transaction is dead" are not the
    # same answer.
    it "answers a malformed identity with no rows and leaves the transaction usable" do
      grant(user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser", resource_external_id: doc1_id)

      [["42", "User", nil], [nil, nil, "abc"]].each do |args|
        expect {
          as_restricted_role do
            db.transaction do
              db.get(Sequel.function(:super_auth_become, *args))
              expect(db[:documents].select_order_map(:name)).to eq([])
              expect(db.get(Sequel.lit("1"))).to eq(1)
            end
          end
        }.not_to raise_error
      end
    end
  end

  # The preflight runs before any DDL, so a refused enable leaves the table
  # exactly as it was.
  describe "preflight" do
    it "refuses a parent column the table lacks, naming the column and the external id type" do
      described_class.disable(:documents)
      expect {
        described_class.enable(:documents, resource_type: "Document", parent: { column: :owner_id, resource_type: "Owner" })
      }.to raise_error(SuperAuth::Error, /documents has no column owner_id.*resource_external_id is bigint.*external_id_type is :bigint/)
      expect(row_security).to eq(relrowsecurity: false, relforcerowsecurity: false)
    end

    it "refuses a parent column outside the family of the external id type, naming both types" do
      db.run "ALTER TABLE documents ADD COLUMN owner_uuid uuid"
      expect {
        described_class.enable(:documents, resource_type: "Document", parent: { column: :owner_uuid, resource_type: "Owner" })
      }.to raise_error(SuperAuth::Error, /documents\.owner_uuid is uuid and super_auth_authorizations\.resource_external_id is bigint.*external_id_type is :bigint/)
    end

    it "refuses a table that does not exist" do
      expect {
        described_class.enable(:nowhere, resource_type: "Nowhere")
      }.to raise_error(SuperAuth::Error, /table nowhere does not exist/)
    end

    it "refuses a wildcard: that is not true or false" do
      expect {
        described_class.enable(:documents, resource_type: "Document", wildcard: nil)
      }.to raise_error(SuperAuth::Error, /wildcard: must be true or false/)
    end
  end

  # A grant on a parent record admits the rows whose column names it: the
  # row's tenancy, read off the row. Folders are ids and nothing more here —
  # the column step compares folder_id against the ids the holder's Folder::*
  # rows name, and no folders table takes part.
  describe "parent grants" do
    let(:parent) { { column: :folder_id, resource_type: %w[Folder::Member Folder::Editor] } }
    # The identity under test: its authorization rows, and its assertion.
    let(:member) { { user_external_id: 42, user_external_type: "SuperAuthRlsSpecUser" } }

    def enable_with_parent(**options)
      described_class.enable(:documents, resource_type: "Document", parent: parent, **options)
    end

    def current?(**options)
      described_class.current?(:documents, resource_type: "Document", parent: parent, **options)
    end

    def as_member(&block)
      become(user_external_id: "42", user_external_type: "SuperAuthRlsSpecUser", &block)
    end

    def folder_of(id)
      db[:documents].where(id: id).get(:folder_id)
    end

    before do
      db.run "ALTER TABLE documents ADD COLUMN folder_id bigint"
      db[:documents].where(id: doc1_id).update(folder_id: 10)
      db[:documents].where(id: doc2_id).update(folder_id: 20)
      enable_with_parent
    end

    describe "a parent-only identity: one Folder::Member row for folder 10 and nothing else" do
      before { grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10) }

      it "sees exactly the rows of its folder" do
        expect(as_member { doc_names }).to eq(["doc1"])
      end

      it "INSERTs with RETURNING into its folder and reads the row back at once" do
        as_member do
          id = db[:documents].insert(name: "doc3", folder_id: 10) # Sequel emits RETURNING id
          expect(id).to be_a(Integer)
          expect(db[:documents].where(id: id).get(:name)).to eq("doc3")
        end
        expect(all_doc_names).to eq(%w[doc1 doc2 doc3])
      end

      it "INSERTs without RETURNING" do
        as_member { db.run "INSERT INTO documents (name, folder_id) VALUES ('doc3', 10)" }
        expect(all_doc_names).to eq(%w[doc1 doc2 doc3])
      end

      it "is refused an INSERT into a folder it does not hold" do
        expect {
          as_member { db[:documents].insert(name: "doc3", folder_id: 20) }
        }.to raise_error(Sequel::DatabaseError, /row-level security/)
        expect(all_doc_names).to eq(%w[doc1 doc2])
      end

      it "is refused an INSERT with no folder: NULL equals no id" do
        expect {
          as_member { db[:documents].insert(name: "doc3") }
        }.to raise_error(Sequel::DatabaseError, /row-level security/)
        expect(all_doc_names).to eq(%w[doc1 doc2])
      end

      it "is refused an UPDATE that moves a row to a folder it does not hold" do
        expect {
          as_member { db[:documents].where(id: doc1_id).update(folder_id: 20) }
        }.to raise_error(Sequel::DatabaseError, /row-level security/)
        expect(folder_of(doc1_id)).to eq(10)
      end

      it "deletes exactly its folder's rows with an unfiltered DELETE" do
        db[:documents].insert(name: "doc3", folder_id: 10)
        expect(as_member { db[:documents].delete }).to eq(2)
        expect(all_doc_names).to eq(["doc2"])
      end

      it "does not see a row with no folder" do
        db[:documents].insert(name: "orphan")
        expect(as_member { doc_names }).to eq(["doc1"])
      end
    end

    it "admits a holder of two folders to both and lets it move a row between them" do
      grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
      grant(**member, resource_external_type: "Folder::Member", resource_external_id: 20)
      as_member do
        expect(doc_names).to eq(%w[doc1 doc2])
        expect(db[:documents].where(id: doc1_id).update(folder_id: 20)).to eq(1)
      end
      expect(folder_of(doc1_id)).to eq(20)
    end

    describe "a per-record identity with no folder" do
      before { grant(**member, resource_external_id: doc1_id) }

      it "sees exactly its row" do
        expect(as_member { doc_names }).to eq(["doc1"])
      end

      # WITH CHECK reuses USING, and USING admits the row by its id whatever
      # the folder column holds, so a per-record holder may file its row
      # under any folder, one nobody granted included. Which folders a
      # holder may file under is capability: the client gates that column
      # on write. Documented behaviour, not a defect.
      it "may set the folder column to any value" do
        as_member { expect(db[:documents].where(id: doc1_id).update(folder_id: 999)).to eq(1) }
        expect(folder_of(doc1_id)).to eq(999)
        as_member { expect(db[:documents].where(id: doc1_id).update(folder_id: nil)).to eq(1) }
        expect(folder_of(doc1_id)).to be_nil
      end
    end

    it "admits a holder of only the second type in the column's list" do
      grant(**member, resource_external_type: "Folder::Editor", resource_external_id: 20)
      expect(as_member { doc_names }).to eq(["doc2"])
    end

    it "never counts a type-level row on the parent type: NULL equals no id" do
      grant(**member, resource_external_type: "Folder::Member")
      expect(as_member { doc_names }).to eq([])
    end

    describe "the type-level step" do
      before { grant(**member) } # (Document, NULL)

      it "admits a wildcard holder to every row, a row with no folder included" do
        db[:documents].insert(name: "orphan")
        expect(as_member { doc_names }).to eq(%w[doc1 doc2 orphan])
      end

      it "is emitted by default" do
        expect(policy_qual).to include("resource_external_id IS NULL")
      end

      it "is dropped by wildcard: false, and a (type, NULL) row then admits nothing" do
        enable_with_parent(wildcard: false)
        expect(policy_qual).not_to include("resource_external_id IS NULL")
        expect(as_member { doc_names }).to eq([])
        expect(current?(wildcard: false)).to be(true)
      end
    end

    # The policy text is the contract: every step plans as an InitPlan or a
    # hashed SubPlan, evaluated once per query, never as a SubPlan re-run
    # for every row of the table. A holder with thousands of rows is where
    # the difference is seconds. Only the Filter lines reference plans; the
    # definition lines below them read "SubPlan n" for both kinds.
    it "plans every step once per query under a heavy holder" do
      heavy = (1..2000).map { |i| { **member, resource_external_type: "Document", resource_external_id: 100_000 + i } }
      db[:super_auth_authorizations].multi_insert(heavy)
      grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
      db.run "ANALYZE super_auth_authorizations"

      plan, count = as_member do
        [db.fetch("EXPLAIN (FORMAT TEXT) SELECT count(*) FROM documents").map { |row| row[:"QUERY PLAN"] }, db[:documents].count]
      end

      references = plan.grep(/Filter:/).flat_map { |line| line.scan(/(?:hashed )?SubPlan \d+/) }
      expect(references.size).to eq(2) # the id step and the folder_id step
      expect(references).to all(start_with("hashed SubPlan"))
      # Only the definition lines, which begin with the keyword: Postgres 17
      # prints an InitPlan's output reference as `(InitPlan 1).col1` inside
      # the Filter line, so grepping for the bare name counts it twice.
      expect(plan.count { |line| line.match?(/^\s*InitPlan \d+/) }).to eq(1) # the type-level step
      expect(count).to eq(1)
    end

    # The other half of the contract: every step must reach its rows through
    # an index on what the policy compares. The identity halves compare
    # a.user_id::text and a.user_external_id::text, expressions no plain btree
    # can serve on a bigint or uuid install, and migration 12's two expression
    # indexes are what makes them seeks — without them each step scans
    # super_auth_authorizations once per statement, on every protected table.
    #
    # enable_seqscan = off, not a bigger fixture: nobody has measured the row
    # count at which the planner picks these unaided, so a spec asserting an
    # unaided choice would flake. Turning off the sequence scan does not hide
    # a missing index either — with the expression indexes dropped the planner
    # falls back to idx_sa_auth_by_resource with the identity demoted to a
    # Filter, which is what the first assertion refuses. Do not delete the
    # SET LOCAL to "fix" this spec.
    it "seeks the identity halves through the expression indexes under a heavy holder" do
      heavy = (1..2000).map { |i| { **member, resource_external_type: "Document", resource_external_id: 100_000 + i } }
      db[:super_auth_authorizations].multi_insert(heavy)
      # Rows of another identity on the same types, per-record and type-level,
      # so every arm's identity slice is narrower than its resource slice and
      # the planner has a reason to prefer the identity index rather than a
      # coin toss between two arms of the same size. The type-level rows are
      # what make the wildcard arm — the one measured at 95% of the statement
      # on a host with 150,000 of them — seek rather than filter.
      other = { user_external_id: 43, user_external_type: "SuperAuthRlsSpecUser" }
      decoys = (1..4000).map { |i|
        { **other, resource_external_type: "Document", resource_external_id: 200_000 + i }
      } + (1..4000).map {
        { **other, resource_external_type: "Document", resource_external_id: nil }
      }
      db[:super_auth_authorizations].multi_insert(decoys)
      grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
      db.run "ANALYZE super_auth_authorizations"

      plan, count = as_member do
        db.run "SET LOCAL enable_seqscan = off"
        [db.fetch("EXPLAIN (FORMAT TEXT) SELECT count(*) FROM documents").map { |row| row[:"QUERY PLAN"] }, db[:documents].count]
      end

      # Index Cond is a seek and Filter is a scan; that distinction is the
      # whole question. A Recheck Cond only ever restates the Index Cond of
      # the bitmap scan below it.
      identity = /current_setting\('super_auth\.user_(id|external_id)'/
      expect(plan.grep(identity)).to all(match(/(Index|Recheck) Cond:/))
      expect(plan.grep(/Filter:/).grep(identity)).to eq([])
      expect(plan.grep(/Seq Scan on super_auth_authorizations/)).to eq([])
      expect(plan.grep(/idx_sa_auth_by_internal_user_text/)).not_to be_empty
      # This suite installs :bigint, so migration 12 builds the external index
      # too; on a :string install its gate skips it and migration 9's
      # idx_sa_auth_by_current_user answers the same predicate as a seek,
      # because varchar->text is a no-op cast.
      expect(plan.grep(/idx_sa_auth_by_current_user_text/)).not_to be_empty
      # A plan assertion that passed while the policy admitted the wrong rows
      # would be worse than none.
      expect(count).to eq(1)
    end

    it "is idempotent and re-runnable on the protected table" do
      grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
      expect { 2.times { enable_with_parent } }.not_to raise_error
      expect(current?).to be(true)
      expect(as_member { doc_names }).to eq(["doc1"])
    end

    describe "versioning" do
      it "stores the version, reach and wildcard as canonical JSON on the policy" do
        expect(policy_rows.map { |row| row[:comment] }).to eq([
          '{"super_auth":2,"reach":{"id":["Document"],"folder_id":["Folder::Member","Folder::Editor"]},"wildcard":true}',
        ])
      end

      it "is current after enable, for the same reach and wildcard only" do
        expect(current?).to be(true)
        expect(current?(wildcard: false)).to be(false)
        expect(described_class.current?(:documents, resource_type: "Document")).to be(false)
        expect(described_class.current?(:documents, resource_type: "Document", parent: { column: :folder_id, resource_type: "Folder::Member" })).to be(false)
      end

      it "is not current after a manual ALTER" do
        db.run "ALTER TABLE documents DISABLE ROW LEVEL SECURITY"
        expect(current?).to be(false)
      end

      # False would say "your parent:/wildcard: arguments are wrong" about a
      # database whose only fault is that nobody re-ran enable, which is the
      # state db:migrate alone leaves a host in. stale answers the same
      # question across every table without raising, so a health check that
      # wants a bare list still has one.
      it "raises rather than answering false once the comment is gone, and stale still answers" do
        expect(described_class.stale).to eq([])
        db.run "COMMENT ON POLICY super_auth ON documents IS NULL"
        expect { current? }.to raise_error(SuperAuth::Error, /was not built by this version of enable/)
        expect(described_class.stale).to eq([:documents])
      end

      it "answers false, and does not raise, for a table carrying no policy of the gem's" do
        described_class.disable(:documents)
        expect(current?).to be(false)
        expect(described_class.stale).to eq([])
      end

      it "reads the reach back from the comment" do
        expect(described_class.reach(:documents)).to eq(id: ["Document"], folder_id: %w[Folder::Member Folder::Editor])
      end

      it "refuses to read a reach from a table with no policy" do
        described_class.disable(:documents)
        expect { described_class.reach(:documents) }.to raise_error(SuperAuth::Error, /documents has no super_auth policy/)
      end
    end

    describe "a 0.8.0 policy" do
      it "is stale and not current, and enable replaces it in place, leaving one policy" do
        current_comment = policy_rows.first[:comment]
        db.run "DROP POLICY super_auth ON documents"
        db.run v1_policy_sql
        expect(policy_qual).to include("IS NULL) OR") # pg_get_expr parenthesises
        expect(described_class.stale).to eq([:documents])
        # No comment at all: built by code that is gone, so there is nothing
        # to compare these arguments against and false would misdiagnose it.
        expect { current? }.to raise_error(SuperAuth::Error, /re-run SuperAuth::RLS.enable/)
        # The shape alone rules it out, whatever the comment says.
        db.run "COMMENT ON POLICY super_auth ON documents IS #{db.literal(current_comment)}"
        expect(described_class.stale).to eq([])
        expect(current?).to be(false)

        enable_with_parent
        expect(described_class.stale).to eq([])
        expect(current?).to be(true)
        expect(policy_rows.map { |row| row[:name] }).to eq(["super_auth"])
        expect(policy_qual).not_to include("IS NULL) OR")
      end

      # Permissive policies are ORed, so a policy left under a previous name
      # would keep admitting beside the new one: the current name is always
      # among the names enable drops.
      it "cannot be left beside the new one under another name" do
        expect(described_class::POLICY_NAMES).to include(described_class::POLICY)
      end
    end

    describe ".explain" do
      it "tags each admitting row with the step that admitted it" do
        grant(**member)
        grant(**member, resource_external_id: doc1_id)
        grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
        grant(**member, resource_external_type: "Folder::Editor", resource_external_id: 20)

        rows = as_member { described_class.explain(:documents, doc1_id) }

        expect(rows.map { |row| row.values_at(:step, :resource_external_type, :resource_external_id) }).to eq([
          [:type_level, "Document", nil],
          [:id, "Document", doc1_id],
          [:folder_id, "Folder::Member", 10],
        ])
        expect(rows.first[:user_external_id]).to eq(42)
      end

      it "returns nothing for a record the identity does not reach, or with no identity asserted" do
        grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
        expect(as_member { described_class.explain(:documents, doc2_id) }).to eq([])
        expect(as_restricted_role { described_class.explain(:documents, doc1_id) }).to eq([])
      end

      it "reads in system context when the role may, and puts the caller's identity back" do
        grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
        steps, names = as_restricted_role(:super_auth_rls_spec_system) do
          db.transaction do
            db.get(Sequel.function(:super_auth_become, "42", "SuperAuthRlsSpecUser", nil))
            [described_class.explain(:documents, doc1_id).map { |row| row[:step] }, doc_names]
          end
        end
        expect(steps).to eq([:folder_id])
        expect(names).to eq(["doc1"])
      end
    end

    describe ".coverage" do
      let!(:doc3_id) { db[:documents].insert(name: "doc3") } # no folder
      let!(:doc4_id) { db[:documents].insert(name: "doc4", folder_id: 10) }
      let(:admin) { SuperAuth::User.create(name: "admin") }
      let(:member_user) { SuperAuth::User.create(name: "member") }
      let(:owner) { SuperAuth::User.create(name: "owner") }

      def node(name, type, id = nil)
        SuperAuth::Resource.create(name: name, external_type: type, external_id: id)
      end

      def holder(user)
        { user_id: user.id, user_external_id: nil, user_external_type: nil }
      end

      # admin: type-level Document, folder 10, per-record doc2, plus a
      # (Folder::Member, NULL) row that must count for nothing. member: folder
      # 10 and per-record doc1. owner: per-record doc2 by a user edge, doc4
      # through a permission, so doc4's node has no user edge. Then a ghost
      # row with no node behind it, and the wildcard node deleted after the
      # compile with its row left in place.
      before do
        all_documents = node("all documents", "Document")
        folder10 = node("folder 10", "Folder::Member", 10)
        doc1_node = node("doc1", "Document", doc1_id)
        doc2_node = node("doc2", "Document", doc2_id)
        doc4_node = node("doc4", "Document", doc4_id)
        read = SuperAuth::Permission.create(name: "read")
        SuperAuth::Edge.create(user: admin, resource: all_documents)
        SuperAuth::Edge.create(user: admin, resource: folder10)
        SuperAuth::Edge.create(user: admin, resource: doc2_node)
        SuperAuth::Edge.create(user: member_user, resource: folder10)
        SuperAuth::Edge.create(user: member_user, resource: doc1_node)
        SuperAuth::Edge.create(user: owner, resource: doc2_node)
        SuperAuth::Edge.create(user: owner, permission: read)
        SuperAuth::Edge.create(permission: read, resource: doc4_node)
        SuperAuth::Authorization.compile!

        grant(user_id: admin.id, resource_external_type: "Folder::Member")
        grant(user_id: SuperAuth::User.create(name: "ghost").id, resource_external_id: doc2_id)
        db[:super_auth_edges].where(resource_id: all_documents.id).delete
        db[:super_auth_resources].where(id: all_documents.id).delete
        @all_documents_id = all_documents.id
        @doc4_node_id = doc4_node.id
      end

      it "fills every bucket" do
        report = described_class.coverage(:documents)

        expect(report.keys).to eq(%i[loss null_parent orphaned_rows widening deletable_nodes])
        expect(report[:loss]).to eq([{ holder: holder(admin), count: 1, ids: [doc3_id] }])
        expect(report[:null_parent]).to eq([{ column: :folder_id, count: 1, ids: [doc3_id] }])
        expect(report[:orphaned_rows]).to eq([
          { type: "Document", type_level: false, count: 1, ids: [nil] },
          { type: "Document", type_level: true, count: 1, ids: [@all_documents_id] },
          { type: "Folder::Member", type_level: true, count: 1, ids: [nil] },
        ])
        expect(report[:widening]).to eq([{ holder: holder(member_user), count: 1, ids: [doc4_id] }])
        expect(report[:deletable_nodes]).to eq([{ type: "Document", count: 1, ids: [@doc4_node_id] }])
      end

      # The compile copies a granted container's edges down to every node in
      # its subtree, so a per-record node under a granted container is that
      # holder's only path to the record even though no edge points at the
      # node itself. Listing it as deletable is the wholesale revocation the
      # bucket exists to prevent.
      it "does not list a per-record node a user edge reaches through an ancestor" do
        container = node("container", nil)
        SuperAuth::Resource.create(name: "doc3 node", external_type: "Document", external_id: doc3_id, parent_id: container.id)
        SuperAuth::Edge.create(user: owner, resource: container)
        SuperAuth::Authorization.compile!

        expect(become(user_id: owner.id.to_s) { doc_names }).to include("doc3")
        expect(described_class.coverage(:documents)[:deletable_nodes])
          .to eq([{ type: "Document", count: 1, ids: [@doc4_node_id] }])
      end

      # Under wildcard: false the type-level step is not in the policy, so a
      # (type, NULL) row admits nothing and deleting it takes nothing away.
      it "reports no loss under wildcard: false" do
        enable_with_parent(wildcard: false)
        expect(described_class.coverage(:documents)[:loss]).to eq([])
      end

      it "never counts a type-level row on a parent type as reach" do
        wild = SuperAuth::User.create(name: "wild")
        grant(user_id: wild.id)
        grant(user_id: wild.id, resource_external_type: "Folder::Member")

        entry = described_class.coverage(:documents)[:loss].find { |row| row[:holder] == holder(wild) }

        expect(entry).to eq(holder: holder(wild), count: 4, ids: [doc1_id, doc2_id, doc3_id, doc4_id])
      end

      # enable grants PUBLIC nothing on the resources and edges tables; a role
      # that runs coverage needs SELECT on them.
      it "runs as the application role inside its own identity, and leaves that identity in place" do
        db.run "GRANT SELECT ON super_auth_resources, super_auth_edges TO super_auth_rls_spec"
        grant(**member, resource_external_type: "Folder::Member", resource_external_id: 10)
        report, names = as_member { [described_class.coverage(:documents), doc_names] }
        expect(report[:deletable_nodes]).to eq([{ type: "Document", count: 1, ids: [@doc4_node_id] }])
        expect(names).to eq(%w[doc1 doc4])
      end
    end
  end

  describe ".enable on a non-Postgres database" do
    it "raises SuperAuth::Error" do
      sqlite = Sequel.sqlite
      expect {
        described_class.enable(:documents, resource_type: "Document", db: sqlite)
      }.to raise_error(SuperAuth::Error, /requires Postgres/)
    end

    # SuperAuth.as does not: a host on SQLite or MySQL, and a Postgres host
    # that has not run the rls generator, has no policy reading the database
    # identity, so `as` sets the one layer that exists and runs the block.
    # RLS.as, the half that raises, is skipped rather than reached.
    it "SuperAuth.as sets current_user, runs the block, and restores" do
      SuperAuth.db # the models bind to the first Sequel::Database created
      sqlite = Sequel.sqlite
      SuperAuth.current_user = :before
      seen = nil
      expect(SuperAuth.as(:someone, db: sqlite) { seen = SuperAuth.current_user; :returned }).to eq(:returned)
      expect(seen).to eq(:someone)
      expect(SuperAuth.current_user).to eq(:before)
    ensure
      SuperAuth.current_user = nil
    end

    it "restores current_user when the block raises" do
      SuperAuth.db
      sqlite = Sequel.sqlite
      SuperAuth.current_user = :before
      expect { SuperAuth.as(:someone, db: sqlite) { raise "boom" } }.to raise_error("boom")
      expect(SuperAuth.current_user).to eq(:before)
    ensure
      SuperAuth.current_user = nil
    end

    it "still opens the transaction and asserts identity once the functions are there" do
      # The memo must not pin the ORM-only answer past the migration that
      # installs them; RLS.enable clears it. The transaction is the visible
      # difference: RLS.as needs one, since the identity dies with it.
      expect(SuperAuth.rls?(SuperAuth.db)).to be true
      in_txn = nil
      as_restricted_role { SuperAuth.as(nil) { in_txn = SuperAuth.db.in_transaction? } }
      expect(in_txn).to be true
    end
  end
end

# The gem's default install types the external id columns varchar(255), the
# one shape where casting the setting instead of the column is not merely slow
# but wrong: a `::varchar(255)` cast built from format_type truncates
# silently, so a longer asserted identity matches a stored 255-character one —
# fail open, which is the wrong direction for an authorization check. The
# shipped predicate casts the column to text and truncates nothing. Its own
# install, because external_id_type is global and the suite above runs
# :bigint.
RSpec.describe "SuperAuth::RLS on a :string install" do
  let(:db) { SuperAuth.db }

  around do |example|
    skip "Postgres only" unless SuperAuth.db.database_type == :postgres

    SuperAuth.external_id_type = :string
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    SuperAuth.install_migrations
    SuperAuth.load
    # Text ids on both sides: the policy compares them with no cast.
    db.run "DROP TABLE IF EXISTS documents"
    db.run "CREATE TABLE documents (id text PRIMARY KEY, name text)"
    db.run "DO $$ BEGIN CREATE ROLE super_auth_rls_spec; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
    db.run "GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO super_auth_rls_spec"
    SuperAuth::RLS.enable(:documents, resource_type: "Document")

    example.run
  ensure
    if SuperAuth.db.database_type == :postgres
      db.run "RESET ROLE"
      db.run "DROP TABLE IF EXISTS documents"
      db.run "DROP OWNED BY super_auth_rls_spec"
      db.run "DROP ROLE IF EXISTS super_auth_rls_spec"
      SuperAuth.uninstall_migrations
    end
  end

  def visible_to(external_id)
    db.run "SET ROLE super_auth_rls_spec"
    db.transaction do
      db.get(Sequel.function(:super_auth_become, external_id, "SuperAuthRlsSpecUser", nil))
      db[:documents].select_order_map(:name)
    end
  ensure
    db.run "RESET ROLE"
  end

  it "does not admit an identity that a varchar(255) cast would truncate onto a stored one" do
    stored = "v" * 255
    db[:documents].insert(id: "doc1", name: "doc1")
    db[:super_auth_authorizations].insert(
      user_external_id: stored, user_external_type: "SuperAuthRlsSpecUser",
      resource_external_type: "Document", resource_external_id: "doc1",
    )

    expect(visible_to(stored)).to eq(["doc1"])
    expect(visible_to("#{stored}ATTACKER-SUFFIX")).to eq([])
  end

  # varchar->text is a no-op cast, so migration 9's plain btree already answers
  # the external half as a seek here and migration 12's gate skips the
  # duplicate. The internal half is int4 on every install and never has one.
  it "leaves the external expression index unbuilt and builds the internal one" do
    expect(db.indexes(:super_auth_authorizations)).to have_key(:idx_sa_auth_by_current_user)
    expect(db.fetch("SELECT to_regclass('idx_sa_auth_by_current_user_text') AS c").first[:c]).to be_nil
    expect(db.fetch("SELECT to_regclass('idx_sa_auth_by_internal_user_text') AS c").first[:c]).not_to be_nil
  end
end
