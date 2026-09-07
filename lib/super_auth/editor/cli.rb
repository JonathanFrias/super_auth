require "optparse"
require "super_auth/editor"

module SuperAuth
  class Editor
    # Boots the editor from the command line: connect, optionally migrate and
    # seed, then serve on loopback. See exe/super_auth-editor.
    module CLI
      DEFAULTS = { host: "127.0.0.1", port: 4666, migrate: false, seed: false }.freeze
      LOOPBACK_BINDS = %w[127.0.0.1 localhost ::1].freeze
      # Host headers accepted when bound to loopback (DNS-rebinding defence).
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze
      WARNING = "WARNING: the editor has no authentication. " \
                "Anyone who can reach this port can rewrite the authorization graph.".freeze

      module_function

      def parse(argv, out: $stdout)
        options = DEFAULTS.dup
        parser = OptionParser.new do |o|
          o.banner = "Usage: super_auth-editor [options]"
          o.on("-H", "--host HOST", "bind address (default #{DEFAULTS[:host]})") { |v| options[:host] = v }
          o.on("-p", "--port PORT", Integer, "port (default #{DEFAULTS[:port]})") { |v| options[:port] = v }
          o.on("--migrate", "run the super_auth Sequel migrations before starting") { options[:migrate] = true }
          o.on("--seed", "replace the whole graph with the Acme Cloud sample (destructive)") { options[:seed] = true }
          o.on("-v", "--version", "print the version") do
            out.puts SuperAuth::VERSION
            exit
          end
          o.on("-h", "--help", "show this help") do
            out.puts o
            out.puts "Reads SUPER_AUTH_DATABASE_URL (required)."
            out.puts WARNING
            exit
          end
        end
        parser.parse!(argv.dup)
        options
      rescue OptionParser::ParseError => e
        raise SuperAuth::Error, "#{e.message}\n#{parser}"
      end

      def run(argv, env: ENV, err: $stderr)
        options = parse(argv)
        url = env["SUPER_AUTH_DATABASE_URL"].to_s.strip
        if url.empty?
          raise SuperAuth::Error, "SUPER_AUTH_DATABASE_URL is not set. Point it at the database that holds " \
                                  "the super_auth tables, e.g. postgres://user:password@localhost/app_development"
        end

        # First Sequel::Database in the process: the models bind to it.
        begin
          SuperAuth.db = Sequel.connect(url)
        rescue Sequel::AdapterNotFound => e
          raise SuperAuth::Error, "#{e.message}. Install the adapter gem for this URL (pg, mysql2 or sqlite3)."
        end

        SuperAuth.install_migrations if options[:migrate]
        begin
          SuperAuth.load
        rescue Sequel::DatabaseError => e
          raise SuperAuth::Error, "super_auth tables not found at #{redact(url)} (#{e.message.lines.first.to_s.strip}). " \
                                  "Run with --migrate to create them, or run your application's migrations."
        end

        if options[:seed]
          require "super_auth/editor/seed"
          counts = SuperAuth::Editor::Seed.run!
          err.puts "Seeded the Acme Cloud sample graph: #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}."
        end

        begin
          require "rackup"
        rescue LoadError
          raise SuperAuth::Error, "The editor needs a Rack server: gem install rackup webrick (puma also works)."
        end

        loopback = LOOPBACK_BINDS.include?(options[:host])
        err.puts WARNING
        err.puts "Bound to #{options[:host]}, which other machines can reach." unless loopback
        err.puts "Editor at http://#{options[:host]}:#{options[:port]}"
        app = SuperAuth::Editor.new(hosts: loopback ? LOOPBACK_HOSTS : nil)
        Rackup::Server.start(app: app, Host: options[:host], Port: options[:port], environment: "deployment")
      end

      def redact(url)
        url.sub(%r{//([^:/@]+):[^@]*@}, '//\1:***@')
      end
    end
  end
end
