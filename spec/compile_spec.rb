require "spec_helper"
require "active_record"
require "super_auth/editor/seed"

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
    db[:super_auth_resources].update(parent_id: nil)
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

  # The delete and the INSERT ... SELECT are one transaction: a source that
  # fails after the delete rolls the delete back too.
  it "leaves the previous table intact when the insert fails" do
    u = SuperAuth::User.create(name: "u")
    %w[a b].each { |n| SuperAuth::Edge.create(user: u, resource: SuperAuth::Resource.create(name: n)) }
    expect(SuperAuth::Authorization.compile!).to eq 2
    broken = db[:no_such_table].select(*SuperAuth::Edge::AUTHORIZATION_COLUMNS)
    allow(SuperAuth::Authorization).to receive(:compile_source).and_return(broken)

    expect { SuperAuth::Authorization.compile! }.to raise_error(Sequel::DatabaseError)
    expect(db[:super_auth_authorizations].count).to eq 2
  end

  describe "as one INSERT ... SELECT" do
    def rows
      db[:super_auth_authorizations].select(*SuperAuth::Edge::AUTHORIZATION_COLUMNS).all.
        map { |row| row.transform_values { |v| v.is_a?(Time) ? v.strftime("%F %T") : v.to_s } }.
        sort_by { |row| row.values }
    end

    # The rows a row-by-row compile wrote: each row of the union, inserted
    # through Sequel as a Hash, the way both twins did before 0.9.0.
    def rows_inserted_one_by_one
      db[:super_auth_authorizations].delete
      SuperAuth::Edge.authorizations.each { |row| db[:super_auth_authorizations].insert(row) }
      rows
    end

    # The editor's seed graph has every strategy, nested groups and roles, a
    # container grant, and a leaf granted twice through different paths.
    it "writes the same rows as a row-by-row compile of the editor seed graph, from both twins" do
      SuperAuth::Editor::Seed.run!
      expected_count = SuperAuth::Edge.authorizations.count
      expect(expected_count).to be > 30

      expect(SuperAuth::Authorization.compile!).to eq expected_count
      from_sequel = rows
      expect(SuperAuth::ActiveRecord::Authorization.compile!).to eq expected_count
      from_active_record = rows
      one_by_one = rows_inserted_one_by_one

      expect(from_sequel.size).to eq expected_count
      expect(from_sequel).to eq one_by_one
      expect(from_active_record).to eq one_by_one
    end

    it "inserts under the union's 28 columns, in its order" do
      expect(SuperAuth::Edge::AUTHORIZATION_COLUMNS).to eq SuperAuth::Edge.authorizations.columns
      expect(SuperAuth::Edge::AUTHORIZATION_COLUMNS.size).to eq 28
      sql = db[:super_auth_authorizations].insert_sql(SuperAuth::Edge::AUTHORIZATION_COLUMNS, SuperAuth::Authorization.compile_source)
      expect(sql).to match(/\AINSERT INTO .super_auth_authorizations. \(.user_id., .*.resource_external_type.\) SELECT /m)
    end
  end
end
