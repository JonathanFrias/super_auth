require "spec_helper"

RSpec.describe "SuperAuth::Authorization.compile!" do
  let(:db) { SuperAuth.db }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_authorizations].delete
    db[:super_auth_edges].delete
    db[:super_auth_groups].update(parent_id: nil)
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].update(parent_id: nil)
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  def compiled
    db[:super_auth_authorizations].select_map([:user_id, :group_id, :role_id, :permission_id, :resource_id]).sort_by { |row| row.map(&:to_s) }
  end

  def graph_rows
    SuperAuth::Edge.authorizations.all.map { |a| a.values_at(:user_id, :group_id, :role_id, :permission_id, :resource_id) }.sort_by { |row| row.map(&:to_s) }
  end

  it "writes exactly the union's rows and returns their count" do
    u = SuperAuth::User.create(name: "u")
    g = SuperAuth::Group.create(name: "g")
    child = SuperAuth::Group.create(name: "child", parent: g)
    r = SuperAuth::Role.create(name: "r")
    p = SuperAuth::Permission.create(name: "p")
    res = SuperAuth::Resource.create(name: "res")
    SuperAuth::Edge.create(user: u, group: child)
    SuperAuth::Edge.create(group: g, role: r)
    SuperAuth::Edge.create(role: r, permission: p)
    SuperAuth::Edge.create(permission: p, resource: res)
    SuperAuth::Edge.create(user: u, resource: res)

    expect(SuperAuth::Authorization.compile!).to eq 2
    expect(compiled).to eq graph_rows
    row = db[:super_auth_authorizations].first(role_id: r.id)
    expect(row[:group_path]).to eq "#{g.id},#{child.id}"
    expect(row[:user_name]).to eq "u"
  end

  it "empties the table on an empty graph" do
    SuperAuth::Edge.create(user: SuperAuth::User.create(name: "u"), resource: SuperAuth::Resource.create(name: "r"))
    SuperAuth::Authorization.compile!
    db[:super_auth_edges].delete

    expect(SuperAuth::Authorization.compile!).to eq 0
    expect(db[:super_auth_authorizations].count).to eq 0
  end

  it "applies a revocation only when recompiled" do
    u = SuperAuth::User.create(name: "u")
    e = SuperAuth::Edge.create(user: u, resource: SuperAuth::Resource.create(name: "r"))
    SuperAuth::Authorization.compile!
    e.delete

    expect(db[:super_auth_authorizations].count).to eq 1
    SuperAuth::Authorization.compile!
    expect(db[:super_auth_authorizations].count).to eq 0
  end

  it "leaves the previous table intact when an insert fails part-way" do
    u = SuperAuth::User.create(name: "u")
    %w[a b].each { |n| SuperAuth::Edge.create(user: u, resource: SuperAuth::Resource.create(name: n)) }
    expect(SuperAuth::Authorization.compile!).to eq 2
    first_row = SuperAuth::Edge.authorizations.first
    broken = Enumerator.new do |y|
      y << first_row
      raise "boom"
    end
    allow(SuperAuth::Edge).to receive(:authorizations).and_return(broken)

    expect { SuperAuth::Authorization.compile! }.to raise_error(RuntimeError, "boom")
    expect(db[:super_auth_authorizations].count).to eq 2
  end
end
