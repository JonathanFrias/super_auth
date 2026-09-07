require "spec_helper"
require "rack"
require "super_auth/editor"
require "super_auth/editor/seed"

# Every request goes through Rack::Lint, so each example is also a Rack 3
# protocol check, and everything runs against the real Sequel models on every
# CI adapter.
RSpec.describe SuperAuth::Editor do
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

  def app(**options)
    Rack::Lint.new(SuperAuth::Editor.new(**options))
  end

  let(:client) { Rack::MockRequest.new(app) }

  def get(path, env = {})
    client.get(path, env)
  end

  def delete(path, env = {})
    client.delete(path, env)
  end

  def post_json(path, body, env = {})
    client.post(path, { "CONTENT_TYPE" => "application/json", input: JSON.generate(body) }.merge(env))
  end

  def post_raw(path, raw, env = {})
    client.post(path, { "CONTENT_TYPE" => "application/json", input: raw }.merge(env))
  end

  def parsed(response)
    JSON.parse(response.body)
  end

  def edges
    db[:super_auth_edges]
  end

  def user(name = "u") = SuperAuth::User.create(name: name)
  def group(name = "g", parent: nil) = SuperAuth::Group.create(name: name, parent: parent)
  def role(name = "r", parent: nil) = SuperAuth::Role.create(name: name, parent: parent)
  def permission(name = "p") = SuperAuth::Permission.create(name: name)
  def resource(name = "res") = SuperAuth::Resource.create(name: name)

  describe "mounting" do
    it "responds to call as the class and as an instance" do
      expect(SuperAuth::Editor).to respond_to(:call)
      expect(Rack::MockRequest.new(Rack::Lint.new(SuperAuth::Editor)).get("/").status).to eq 200
      expect(get("/").status).to eq 200
    end

    it "serves the index for an empty PATH_INFO under a mount prefix" do
      env = Rack::MockRequest.env_for("/super_auth/editor")
      env["SCRIPT_NAME"] = "/super_auth/editor"
      env["PATH_INFO"] = ""
      status, headers, body = app.call(env)
      html = +""
      body.each { |chunk| html << chunk }
      body.close if body.respond_to?(:close)

      expect(status).to eq 200
      expect(headers["content-type"]).to eq "text/html; charset=utf-8"
      expect(html).to include("graph editor")
    end
  end

  describe "the HTML" do
    it "is served with no-store and frame denial" do
      response = get("/")
      expect(response.status).to eq 200
      expect(response.headers["content-type"]).to eq "text/html; charset=utf-8"
      expect(response.headers["x-frame-options"]).to eq "DENY"
      expect(response.headers["cache-control"]).to eq "no-store"
      expect(response.body).to include("SuperAuth · Graph Editor")
    end

    it "calls the API relative to the page, never at the origin root" do
      expect(get("/").body).not_to match(%r{fetch\(["'`]/api})
      expect(get("/").body).to include('const API = location.pathname')
    end

    it "escapes every node name and error message it interpolates into markup" do
      html = get("/").body
      # nameFor(...) and j.error feed innerHTML; each use must be wrapped in escapeHtml(...)
      expect(html.scan(/\$\{[^}]*nameFor\([^}]*\}/)).to all(include("escapeHtml("))
      expect(html.scan(/\$\{[^}]*\.error[^}]*\}/)).to all(include("escapeHtml("))
    end
  end

  describe "request guards" do
    it "requires application/json on POST" do
      response = client.post("/api/nodes/user", "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "name=x")
      expect(response.status).to eq 415
      expect(SuperAuth::User.count).to eq 0
    end

    it "refuses cross-site writes" do
      u = user
      g = group
      response = post_json("/api/edges", { a_type: "user", a_id: u.id, b_type: "group", b_id: g.id }, "HTTP_SEC_FETCH_SITE" => "cross-site")
      expect(response.status).to eq 403
      expect(edges.count).to eq 0

      expect(delete("/api/nodes/user/#{u.id}", "HTTP_SEC_FETCH_SITE" => "cross-site").status).to eq 403
      expect(SuperAuth::User.count).to eq 1
    end

    it "accepts same-origin and header-less writes" do
      u = user
      g = group
      expect(post_json("/api/edges", { a_type: "user", a_id: u.id, b_type: "group", b_id: g.id }, "HTTP_SEC_FETCH_SITE" => "same-origin").status).to eq 201
      expect(post_json("/api/nodes/user", { name: "v" }).status).to eq 201
    end

    it "rejects unlisted Host headers only when hosts are given" do
      guarded = Rack::MockRequest.new(app(hosts: %w[localhost 127.0.0.1 [::1]]))
      expect(guarded.get("/api/graph", "HTTP_HOST" => "evil.example:4666").status).to eq 403
      expect(guarded.get("/", "HTTP_HOST" => "evil.example").status).to eq 403
      expect(guarded.get("/api/graph", "HTTP_HOST" => "localhost:4666").status).to eq 200
      expect(guarded.get("/api/graph", "HTTP_HOST" => "127.0.0.1").status).to eq 200
      expect(guarded.get("/api/graph", "HTTP_HOST" => "[::1]:4666").status).to eq 200

      expect(get("/api/graph", "HTTP_HOST" => "evil.example").status).to eq 200
    end
  end

  describe "GET /api/graph" do
    it "returns six empty collections and a zero compiled count on an empty database" do
      response = get("/api/graph")
      expect(response.status).to eq 200
      expect(response.headers["content-type"]).to eq "application/json; charset=utf-8"
      expect(response.headers["cache-control"]).to eq "no-store"
      expect(parsed(response)).to eq(
        "groups" => [], "roles" => [], "users" => [], "permissions" => [], "resources" => [], "edges" => [],
        "authorizations_count" => 0
      )
    end

    it "returns rows sorted by name with the documented keys per type" do
      parent = group("Zed")
      group("Alpha", parent: parent)
      role("Writer")
      SuperAuth::User.create(name: "Bea", external_id: "7", external_type: "Account")
      permission("read")
      SuperAuth::Resource.create(name: "doc", external_id: "9", external_type: "Document")
      e = SuperAuth::Edge.create(user: SuperAuth::User.first, group: parent)

      body = parsed(get("/api/graph"))
      expect(body["groups"].map { |g| g["name"] }).to eq %w[Alpha Zed]
      expect(body["groups"].first.keys).to match_array %w[id name parent_id]
      expect(body["groups"].first["parent_id"]).to eq parent.id
      expect(body["roles"].first.keys).to match_array %w[id name parent_id]
      expect(body["users"].first).to eq("id" => SuperAuth::User.first.id, "name" => "Bea", "external_id" => "7", "external_type" => "Account")
      expect(body["permissions"].first.keys).to match_array %w[id name]
      expect(body["resources"].first.keys).to match_array %w[id name external_id external_type super_auth_label]
      expect(body["edges"]).to eq [{
        "id" => e.id, "user_id" => SuperAuth::User.first.id, "group_id" => parent.id,
        "role_id" => nil, "permission_id" => nil, "resource_id" => nil,
      }]
    end

    it "carries the stored label, which is what the editor renders in place of Type#id" do
      SuperAuth::Resource.create(name: "Claim", external_id: "9", external_type: "Claim", super_auth_label: "Gulf War presumptive")
      SuperAuth::Resource.create(name: "Claim", external_id: "10", external_type: "Claim")

      labels = parsed(get("/api/graph"))["resources"].map { |r| r["super_auth_label"] }
      expect(labels).to match_array ["Gulf War presumptive", nil]
    end
  end

  describe "POST /api/nodes/:type" do
    %w[user group role permission resource].each do |type|
      it "creates a #{type}" do
        response = post_json("/api/nodes/#{type}", { name: "  New #{type}  " })
        expect(response.status).to eq 201
        body = parsed(response)
        expect(body.keys).to match_array %w[id name parent_id external_id external_type]
        expect(body["name"]).to eq "New #{type}"
        expect(body["parent_id"]).to be_nil
        expect(SuperAuth.const_get(SuperAuth::Editor::TYPES[type]).count).to eq 1
      end
    end

    it "nests groups and roles under an existing parent" do
      g = group("parent")
      r = role("parent role")
      expect(parsed(post_json("/api/nodes/group", { name: "child", parent_id: g.id }))["parent_id"]).to eq g.id
      expect(parsed(post_json("/api/nodes/role", { name: "child", parent_id: r.id.to_s }))["parent_id"]).to eq r.id
      expect(SuperAuth::Group.first(name: "child").parent_id).to eq g.id
    end

    it "rejects a parent that does not exist" do
      expect(post_json("/api/nodes/group", { name: "orphan", parent_id: 999_999 }).status).to eq 422
      expect(SuperAuth::Group.count).to eq 0
    end

    it "rejects a parent on types that are not trees, and ignores a null one" do
      expect(post_json("/api/nodes/user", { name: "u", parent_id: 1 }).status).to eq 422
      expect(post_json("/api/nodes/permission", { name: "p", parent_id: 1 }).status).to eq 422
      expect(SuperAuth::User.count).to eq 0
      expect(post_json("/api/nodes/permission", { name: "p", parent_id: nil }).status).to eq 201
    end

    it "rejects non-integer parents" do
      g = group
      ["abc", 1.9, true, -1, "1abc"].each do |bad|
        expect(post_json("/api/nodes/group", { name: "x", parent_id: bad }).status).to eq(422), bad.inspect
      end
      expect(SuperAuth::Group.count).to eq 1
      expect(g).to be_a(SuperAuth::Group)
    end

    it "requires a name and caps it at 255 characters" do
      expect(post_json("/api/nodes/user", {}).status).to eq 422
      expect(post_json("/api/nodes/user", { name: "   " }).status).to eq 422
      expect(post_json("/api/nodes/user", { name: nil }).status).to eq 422
      expect(post_json("/api/nodes/user", { name: "x" * 256 }).status).to eq 422
      expect(SuperAuth::User.count).to eq 0
      expect(post_json("/api/nodes/user", { name: "x" * 255 }).status).to eq 201
    end

    it "ignores keys other than name and parent_id" do
      response = post_json("/api/nodes/user", { name: "u", id: 999, external_id: "1", external_type: "Admin" })
      body = parsed(response)
      expect(body["id"]).not_to eq 999
      expect(body["external_id"]).to be_nil
      expect(body["external_type"]).to be_nil
    end

    it "refuses to create a user named system" do
      expect(post_json("/api/nodes/user", { name: "system" }).status).to eq 422
      expect(SuperAuth::User.count).to eq 0
    end

    it "rejects bodies that are not a JSON object" do
      ["[1,2]", "null", "\"str\"", "42", "{not json", ""].each do |raw|
        expect(post_raw("/api/nodes/user", raw).status).to eq(400), raw.inspect
      end
      expect(client.post("/api/nodes/user", "CONTENT_TYPE" => "application/json").status).to eq 400
      expect(SuperAuth::User.count).to eq 0
    end

    it "rejects oversized bodies" do
      expect(post_raw("/api/nodes/user", JSON.generate(name: "x" * 70_000)).status).to eq 413
    end

    it "returns 404 for an unknown type" do
      expect(post_json("/api/nodes/bogus", { name: "x" }).status).to eq 404
    end
  end

  describe "DELETE /api/nodes/:type/:id" do
    it "deletes a group with its edges, re-parents its children, and leaves the rest alone" do
      g = group("g")
      child = group("child", parent: g)
      other = group("other")
      u = user
      r = role
      SuperAuth::Edge.create(user: u, group: g)
      SuperAuth::Edge.create(group: g, role: r)
      kept = SuperAuth::Edge.create(user: u, group: other)

      response = delete("/api/nodes/group/#{g.id}")
      expect(response.status).to eq 200
      expect(parsed(response)).to eq("ok" => true)
      expect(SuperAuth::Group[g.id]).to be_nil
      expect(SuperAuth::Group[child.id].parent_id).to be_nil
      expect(edges.map(:id)).to eq [kept.id]
      expect(SuperAuth::User[u.id]).not_to be_nil
    end

    it "deletes a role the same way" do
      r = role("r")
      child = role("child", parent: r)
      SuperAuth::Edge.create(role: r, permission: permission)

      expect(delete("/api/nodes/role/#{r.id}").status).to eq 200
      expect(SuperAuth::Role[r.id]).to be_nil
      expect(SuperAuth::Role[child.id].parent_id).to be_nil
      expect(edges.count).to eq 0
    end

    it "deletes a user and its edges" do
      u = user
      SuperAuth::Edge.create(user: u, resource: resource)
      expect(delete("/api/nodes/user/#{u.id}").status).to eq 200
      expect(SuperAuth::User[u.id]).to be_nil
      expect(edges.count).to eq 0
    end

    it "pins that a deleted node's children become roots rather than joining the grandparent" do
      a = group("a")
      b = group("b", parent: a)
      c = group("c", parent: b)
      delete("/api/nodes/group/#{b.id}")
      expect(SuperAuth::Group[c.id].parent_id).to be_nil
    end

    it "returns 404 for unknown types and ids and does not coerce them" do
      u = user
      expect(delete("/api/nodes/bogus/#{u.id}").status).to eq 404
      expect(delete("/api/nodes/user/abc").status).to eq 404
      expect(delete("/api/nodes/user/#{u.id}abc").status).to eq 404
      expect(delete("/api/nodes/user/999999").status).to eq 404
      expect(SuperAuth::User[u.id]).not_to be_nil
    end

    it "leaves nothing half-done when the delete fails part-way" do
      g = group("g")
      child = group("child", parent: g)
      SuperAuth::Edge.create(user: user, group: g)
      # Skip the edge cleanup so the final delete hits the foreign key.
      allow(SuperAuth::Edge).to receive(:where).and_return(double("edges", delete: 0))

      response = delete("/api/nodes/group/#{g.id}")
      expect(response.status).to eq 422
      expect(SuperAuth::Group[g.id]).not_to be_nil
      expect(SuperAuth::Group[child.id].parent_id).to eq g.id
      expect(edges.count).to eq 1
    end
  end

  describe "POST /api/edges" do
    let(:nodes) { { "user" => user, "group" => group, "role" => role, "permission" => permission, "resource" => resource } }

    def edge_body(a, b, extra = {})
      { a_type: a, a_id: nodes[a].id, b_type: b, b_id: nodes[b].id }.merge(extra)
    end

    SuperAuth::Editor::ALLOWED_PAIRS.each do |a, b|
      it "creates a #{a} <-> #{b} edge with exactly two ids" do
        response = post_json("/api/edges", edge_body(a, b))
        expect(response.status).to eq 201
        row = edges.first
        expect(row.values_at(:user_id, :group_id, :role_id, :permission_id, :resource_id).compact.size).to eq 2
        expect(parsed(response)["id"]).to eq row[:id]
      end
    end

    it "rejects the pairs no strategy reads" do
      expect(post_json("/api/edges", edge_body("group", "resource")).status).to eq 422
      expect(post_json("/api/edges", edge_body("resource", "role")).status).to eq 422
      expect(edges.count).to eq 0
    end

    it "rejects malformed endpoints" do
      expect(post_json("/api/edges", edge_body("user", "user")).status).to eq 422
      expect(post_json("/api/edges", edge_body("user", "group", b_type: "bogus")).status).to eq 422
      expect(post_json("/api/edges", edge_body("user", "group", a_id: nil)).status).to eq 422
      expect(post_json("/api/edges", edge_body("user", "group", a_id: "abc")).status).to eq 422
      expect(post_json("/api/edges", edge_body("user", "group", a_id: 1.5)).status).to eq 422
      expect(post_json("/api/edges", {}).status).to eq 422
      expect(edges.count).to eq 0
    end

    it "returns 404 for an endpoint that does not exist" do
      expect(post_json("/api/edges", edge_body("user", "group", b_id: 999_999)).status).to eq 404
      expect(edges.count).to eq 0
    end

    it "is idempotent and direction-insensitive" do
      first = post_json("/api/edges", edge_body("user", "group"))
      again = post_json("/api/edges", edge_body("user", "group"))
      reversed = post_json("/api/edges", { a_type: "group", a_id: nodes["group"].id, b_type: "user", b_id: nodes["user"].id })
      expect(first.status).to eq 201
      expect(again.status).to eq 200
      expect(reversed.status).to eq 200
      expect([again, reversed].map { |r| parsed(r)["id"] }.uniq).to eq [parsed(first)["id"]]
      expect(edges.count).to eq 1
    end

    it "ignores extra columns in the body" do
      post_json("/api/edges", edge_body("user", "resource", role_id: nodes["role"].id, permission_id: 5))
      expect(edges.first.values_at(:role_id, :permission_id)).to eq [nil, nil]
    end

    it "does not change the compiled table until compile runs" do
      post_json("/api/edges", edge_body("user", "resource"))
      expect(db[:super_auth_authorizations].count).to eq 0
      expect(parsed(get("/api/graph"))["authorizations_count"]).to eq 0
    end
  end

  describe "DELETE /api/edges/:id" do
    it "deletes an edge" do
      e = SuperAuth::Edge.create(user: user, resource: resource)
      expect(delete("/api/edges/#{e.id}").status).to eq 200
      expect(edges.count).to eq 0
    end

    it "returns 404 for unknown or non-integer ids" do
      e = SuperAuth::Edge.create(user: user, resource: resource)
      expect(delete("/api/edges/999999").status).to eq 404
      expect(delete("/api/edges/#{e.id}x").status).to eq 404
      expect(edges.count).to eq 1
    end
  end

  describe "POST /api/compile" do
    it "compiles the graph and revocation takes effect only through it" do
      u = user("u")
      res = resource("doc")
      e = SuperAuth::Edge.create(user: u, resource: res)

      response = client.post("/api/compile")
      expect(response.status).to eq 200
      expect(parsed(response)).to eq("count" => 1)
      expect(db[:super_auth_authorizations].count).to eq 1
      expect(parsed(get("/api/graph"))["authorizations_count"]).to eq 1

      delete("/api/edges/#{e.id}")
      expect(db[:super_auth_authorizations].count).to eq 1
      expect(parsed(client.post("/api/compile"))).to eq("count" => 0)
      expect(db[:super_auth_authorizations].count).to eq 0
    end
  end

  describe "unknown routes" do
    it "answers 404 JSON for unknown paths and methods" do
      expect(get("/nope").status).to eq 404
      expect(client.put("/api/graph").status).to eq 404
      expect(parsed(get("/nope"))).to eq("error" => "not found")
    end
  end

  describe "the tables being absent" do
    # In a fresh process SuperAuth.load raises Sequel::DatabaseError when the
    # tables do not exist; the models are already loaded here, so simulate it.
    it "answers 503 instead of crashing" do
      hide_const("SuperAuth::User")
      allow(SuperAuth).to receive(:load).and_raise(Sequel::DatabaseError, "no such table: super_auth_users")
      response = get("/api/graph")
      expect(response.status).to eq 503
      expect(parsed(response)["error"]).to include("--migrate")
    end
  end

  describe SuperAuth::Editor::Seed do
    it "builds the documented Acme Cloud graph, idempotently, and leaves nothing compiled" do
      expected = { groups: 5, roles: 5, users: 10, permissions: 12, resources: 9, edges: 42 }
      expect(described_class.run!).to eq expected
      expect(described_class.run!).to eq expected
      expect(db[:super_auth_authorizations].count).to eq 0
    end

    it "grants what the comments promise" do
      described_class.run!
      access = SuperAuth::Edge.authorizations.all.group_by { |a| a[:user_name] }.transform_values { |rows| rows.map { |a| a[:resource_name] }.uniq.sort }

      expect(access["Nina"]).to be_nil
      expect(access["Alice"]).to include("app_database", "source_repo", "production_cluster")
      expect(access["Bob"]).not_to include("app_database")
      expect(access["Bob"]).to include("marketing_site")
      expect(access["Frank"]).to include("customer_accounts", "support_tickets")
      expect(access["Erin"]).to eq ["support_tickets"]
      expect(access["Riley"]).to eq %w[general_ledger support_tickets]
      expect(access["Morgan"]).to eq %w[general_ledger production_cluster support_tickets]
    end
  end
end
