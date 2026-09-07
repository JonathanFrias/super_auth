require "json"
require "super_auth"

module SuperAuth
  # A small Rack application that edits the authorization graph: five boxes of
  # records, client-side traversal, node and edge CRUD, and a Recompile button.
  # Rails-free; it needs only SuperAuth.db to be connected and the tables to
  # exist. Mount it as `run SuperAuth::Editor` (Rack) or
  # `mount SuperAuth::Editor => "/super_auth/editor"` (Rails), or run
  # `super_auth-editor`, which serves it on loopback.
  #
  # It has no authentication of its own. Anyone who can reach it can rewrite
  # the graph, so the host must put its own authentication in front of the
  # mount. Two stdlib-only guards remain: writes must be application/json (a
  # cross-origin browser cannot send that without a CORS preflight, which is
  # never answered) and cross-site fetches are refused; `hosts:` additionally
  # rejects any other Host header, the DNS-rebinding defence the executable
  # turns on for loopback.
  #
  # Edits change the graph, not runtime access: ByCurrentUser and the RLS
  # policies read the compiled super_auth_authorizations table, so the UI
  # shows its row count and offers POST /api/compile.
  class Editor
    TYPES = {
      "user" => :User, "group" => :Group, "role" => :Role,
      "permission" => :Permission, "resource" => :Resource,
    }.freeze
    COLUMNS = {
      "user" => :user_id, "group" => :group_id, "role" => :role_id,
      "permission" => :permission_id, "resource" => :resource_id,
    }.freeze
    NESTED = %w[group role].freeze
    # The pairs the path strategies read (see Edge.authorizations), unordered.
    # The models also accept group->resource and role->resource rows, but no
    # strategy reads them, so they would grant nothing.
    ALLOWED_PAIRS = [
      %w[user group], %w[user role], %w[user permission], %w[user resource],
      %w[group role], %w[group permission], %w[role permission], %w[permission resource],
    ].map(&:sort).freeze
    EMPTY_EDGE = { user_id: nil, group_id: nil, role_id: nil, permission_id: nil, resource_id: nil }.freeze
    INDEX_HTML = File.read(File.join(__dir__, "editor", "index.html")).freeze
    MAX_BODY = 64 * 1024
    ID = /\A\d+\z/
    NAME_MAX = 255

    def self.call(env)
      (@default ||= new).call(env)
    end

    # hosts: host names (port ignored) this app answers to; nil disables the check.
    def initialize(hosts: nil)
      @hosts = hosts && hosts.map { |h| h.to_s.downcase }
    end

    def call(env)
      return forbidden("host not allowed") if @hosts && !@hosts.include?(host_of(env))

      begin
        SuperAuth.load unless defined?(SuperAuth::User)
      rescue Sequel::DatabaseError
        return json(503, error: "super_auth tables not found; run the migrations (super_auth-editor --migrate, or your application's)")
      end

      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"].to_s
      path = "/" if path.empty?
      if %w[POST DELETE].include?(method) && env["HTTP_SEC_FETCH_SITE"] == "cross-site"
        return forbidden("cross-site requests are not accepted")
      end

      route(method, path, env)
    rescue Sequel::Error
      json(422, error: "the database rejected the change")
    end

    private

    def route(method, path, env)
      if method == "GET" && path == "/"
        html
      elsif method == "GET" && path == "/api/graph"
        json(200, graph)
      elsif method == "POST" && path == "/api/compile"
        json(200, count: SuperAuth::Authorization.compile!)
      elsif method == "POST" && path == "/api/edges"
        with_body(env) { |body| create_edge(body) }
      elsif method == "DELETE" && (m = path.match(%r{\A/api/edges/([^/]+)\z}))
        delete_edge(m[1])
      elsif method == "POST" && (m = path.match(%r{\A/api/nodes/([^/]+)\z}))
        with_body(env) { |body| create_node(m[1], body) }
      elsif method == "DELETE" && (m = path.match(%r{\A/api/nodes/([^/]+)/([^/]+)\z}))
        delete_node(m[1], m[2])
      else
        json(404, error: "not found")
      end
    end

    # ---- reads ----

    def graph
      {
        groups: nodes(:Group, :parent_id),
        roles: nodes(:Role, :parent_id),
        users: nodes(:User, :external_id, :external_type),
        permissions: nodes(:Permission),
        resources: nodes(:Resource, :external_id, :external_type),
        edges: SuperAuth::Edge.order(:id).map { |e| edge_json(e) },
        authorizations_count: SuperAuth::Authorization.count,
      }
    end

    def nodes(model, *extra)
      SuperAuth.const_get(model).order(:name, :id).map do |n|
        row = { id: n.id, name: n.name }
        extra.each { |column| row[column] = n[column] }
        row
      end
    end

    # ---- writes ----

    def create_node(type, body)
      model = model_for(type) or return json(404, error: "unknown node type")
      name = body["name"].to_s.strip
      return json(422, error: "name is required") if name.empty?
      return json(422, error: "name is too long (#{NAME_MAX} characters max)") if name.length > NAME_MAX
      return json(422, error: "the name \"system\" is reserved") if type == "user" && name == "system"

      attrs = { name: name }
      parent = body["parent_id"]
      unless parent.nil?
        return json(422, error: "#{type} records cannot have a parent") unless NESTED.include?(type)
        return json(422, error: "parent_id must be an integer") unless integer_id?(parent)
        return json(422, error: "parent not found") unless model[parent.to_i]
        attrs[:parent_id] = parent.to_i
      end

      json(201, node_json(model.create(attrs)))
    end

    def delete_node(type, id)
      model = model_for(type) or return json(404, error: "unknown node type")
      record = integer_id?(id) && model[id.to_i]
      return json(404, error: "not found") unless record

      SuperAuth.db.transaction do
        SuperAuth::Edge.where(COLUMNS[type] => record.id).delete
        # Children become roots: the deny-safe choice, and required before the
        # delete on MySQL, which checks the self-referencing key row by row.
        model.where(parent_id: record.id).update(parent_id: nil) if NESTED.include?(type)
        model.where(id: record.id).delete
      end
      json(200, ok: true)
    end

    def create_edge(body)
      a_type = body["a_type"].to_s
      b_type = body["b_type"].to_s
      return json(422, error: "unknown node type") unless COLUMNS[a_type] && COLUMNS[b_type]
      return json(422, error: "an edge links two different node types") if a_type == b_type
      unless ALLOWED_PAIRS.include?([a_type, b_type].sort)
        return json(422, error: "no path strategy reads #{a_type} -> #{b_type} edges; it would grant nothing")
      end
      return json(422, error: "ids must be integers") unless integer_id?(body["a_id"]) && integer_id?(body["b_id"])

      a_id = body["a_id"].to_i
      b_id = body["b_id"].to_i
      return json(404, error: "#{a_type} #{a_id} not found") unless model_for(a_type)[a_id]
      return json(404, error: "#{b_type} #{b_id} not found") unless model_for(b_type)[b_id]

      # The full five-column hash, so a row created here always has exactly two ids.
      attrs = EMPTY_EDGE.merge(COLUMNS[a_type] => a_id, COLUMNS[b_type] => b_id)
      if (edge = SuperAuth::Edge.where(attrs).first)
        json(200, edge_json(edge))
      else
        json(201, edge_json(SuperAuth::Edge.create(attrs)))
      end
    end

    def delete_edge(id)
      edge = integer_id?(id) && SuperAuth::Edge[id.to_i]
      return json(404, error: "not found") unless edge

      edge.delete
      json(200, ok: true)
    end

    # ---- helpers ----

    def model_for(type)
      TYPES[type] && SuperAuth.const_get(TYPES[type])
    end

    def integer_id?(value)
      (value.is_a?(Integer) && value >= 0) || (value.is_a?(String) && value.match?(ID))
    end

    def node_json(record)
      {
        id: record.id,
        name: record.name,
        parent_id: record.respond_to?(:parent_id) ? record.parent_id : nil,
        external_id: record.respond_to?(:external_id) ? record.external_id : nil,
        external_type: record.respond_to?(:external_type) ? record.external_type : nil,
      }
    end

    def edge_json(edge)
      { id: edge.id, user_id: edge.user_id, group_id: edge.group_id, role_id: edge.role_id,
        permission_id: edge.permission_id, resource_id: edge.resource_id }
    end

    def with_body(env)
      media_type = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
      return json(415, error: "send application/json") unless media_type == "application/json"

      input = env["rack.input"]
      raw = input ? input.read(MAX_BODY + 1).to_s : ""
      return json(413, error: "body too large") if raw.bytesize > MAX_BODY

      body = raw.empty? ? nil : JSON.parse(raw)
      return json(400, error: "body must be a JSON object") unless body.is_a?(Hash)

      yield body
    rescue JSON::ParserError
      json(400, error: "body must be a JSON object")
    end

    def host_of(env)
      host = env["HTTP_HOST"].to_s.downcase
      host.start_with?("[") ? host[/\A\[[^\]]*\]/].to_s : host.split(":").first.to_s
    end

    def json(status, payload)
      [status, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }, [JSON.generate(payload)]]
    end

    def html
      [200, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store", "x-frame-options" => "DENY" }, [INDEX_HTML]]
    end

    def forbidden(message)
      json(403, error: message)
    end
  end
end
