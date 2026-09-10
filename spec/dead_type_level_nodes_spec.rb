require "spec_helper"
require "active_record"

RSpec.describe "SuperAuth::ActiveRecord::Resource.dead_type_level_nodes" do
  before do
    SuperAuth.install_migrations
    SuperAuth.load
    SuperAuth.db[:super_auth_authorizations].delete
    SuperAuth.db[:super_auth_edges].delete
    SuperAuth.db[:super_auth_resources].update(parent_id: nil)
    SuperAuth.db[:super_auth_resources].delete

    # dead_type_level_nodes resolves a node's external_type by name, so the
    # stand-ins need real constants; stub_const names them for the example.
    # The `super_auth` macro reads the class name, so it runs after naming.
    # Both point at a table that always exists; the scope is never evaluated
    # here, only its presence.
    scoped = Class.new(ActiveRecord::Base) { self.table_name = "super_auth_users" }
    stub_const("SuperAuthDeadSpecScoped", scoped)
    scoped.super_auth
    stub_const("SuperAuthDeadSpecPlain", Class.new(ActiveRecord::Base) { self.table_name = "super_auth_users" })
  end

  it "lists the type-level nodes whose type resolves to no scoped model" do
    alive = SuperAuth::ActiveRecord::Resource.create!(name: "scoped", external_type: "SuperAuthDeadSpecScoped")
    unscoped = SuperAuth::ActiveRecord::Resource.create!(name: "plain", external_type: "SuperAuthDeadSpecPlain")
    missing = SuperAuth::ActiveRecord::Resource.create!(name: "gone", external_type: "SuperAuthNoSuchModelXyz")
    # A per-record node is never type-level, whatever its type resolves to.
    SuperAuth::ActiveRecord::Resource.create!(name: "record", external_type: "SuperAuthNoSuchModelXyz", external_id: "1")

    dead = SuperAuth::ActiveRecord::Resource.dead_type_level_nodes
    expect(dead.map(&:id)).to match_array [unscoped.id, missing.id]
    expect(dead.map(&:id)).not_to include(alive.id)
  end

  it "is empty when every type-level node names a scoped model" do
    SuperAuth::ActiveRecord::Resource.create!(name: "scoped", external_type: "SuperAuthDeadSpecScoped")
    expect(SuperAuth::ActiveRecord::Resource.dead_type_level_nodes).to be_empty
  end
end
