require "spec_helper"

# The trigger's behaviour is pinned in spec/audit/graph_spec.rb; this file
# pins the installer a host calls from its test setup, since db/schema.rb
# cannot carry a trigger and db:test:prepare loads schema.rb.
RSpec.describe SuperAuth::TreeGuard do
  let(:db) { SuperAuth.db }

  before do
    skip "Postgres only" unless db.database_type == :postgres
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_authorizations].delete
    db[:super_auth_edges].delete
    db[:super_auth_resources].update(parent_id: nil)
    db[:super_auth_resources].delete
  end

  after do
    # Leave the guard as migration 13 installed it for the rest of the suite.
    described_class.install(db: db) if db.database_type == :postgres
  end

  def close_cycle!
    a = db[:super_auth_resources].insert(name: "a")
    b = db[:super_auth_resources].insert(name: "b", parent_id: a)
    db[:super_auth_resources].where(id: a).update(parent_id: b)
  end

  it "is installed by migration 13, and reports it" do
    expect(described_class.installed?(db: db)).to be true
  end

  it "can be removed and reinstalled, and refuses a cycle only while installed" do
    expect(described_class.remove(db: db)).to be true
    expect(described_class.installed?(db: db)).to be false
    expect { close_cycle! }.not_to raise_error   # schema.rb-shaped database: nothing refuses it

    db[:super_auth_resources].update(parent_id: nil)
    db[:super_auth_resources].delete
    expect(described_class.install(db: db)).to be true
    expect(described_class.installed?(db: db)).to be true
    expect { close_cycle! }.to raise_error(Sequel::CheckConstraintViolation, /would close a cycle/)
  end

  it "installs idempotently" do
    expect(described_class.install(db: db)).to be true
    expect(described_class.install(db: db)).to be true
    expect(described_class.installed?(db: db)).to be true
  end
end
