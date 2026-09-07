require "spec_helper"
require "stringio"
require "socket"
require "tmpdir"
require "net/http"
require "open3"
require "rbconfig"
require "super_auth/editor/cli"

RSpec.describe SuperAuth::Editor::CLI do
  describe ".parse" do
    it "defaults to loopback, port 4666, no migration, no seed" do
      expect(described_class.parse([])).to eq(host: "127.0.0.1", port: 4666, migrate: false, seed: false)
    end

    it "reads every option" do
      expect(described_class.parse(%w[--host 0.0.0.0 --port 5000 --migrate --seed])).to eq(
        host: "0.0.0.0", port: 5000, migrate: true, seed: true
      )
      expect(described_class.parse(%w[-H ::1 -p 1234])).to include(host: "::1", port: 1234)
    end

    it "turns option errors into SuperAuth::Error" do
      expect { described_class.parse(%w[--port x]) }.to raise_error(SuperAuth::Error, /port/i)
      expect { described_class.parse(%w[--bogus]) }.to raise_error(SuperAuth::Error, /bogus/)
    end

    it "prints help with the loopback default and the warning, and never a database URL" do
      out = StringIO.new
      expect { described_class.parse(%w[--help], out: out) }.to raise_error(SystemExit)
      expect(out.string).to include("127.0.0.1")
      expect(out.string).to include("SUPER_AUTH_DATABASE_URL")
      expect(out.string).to include("no authentication")
      expect(out.string).not_to include("postgres://")
    end
  end

  describe ".run" do
    it "refuses to start without SUPER_AUTH_DATABASE_URL, before touching any connection" do
      expect(Sequel).not_to receive(:connect)
      expect { described_class.run([], env: {}) }.to raise_error(SuperAuth::Error, /SUPER_AUTH_DATABASE_URL/)
      expect { described_class.run([], env: { "SUPER_AUTH_DATABASE_URL" => "  " }) }.to raise_error(SuperAuth::Error, /SUPER_AUTH_DATABASE_URL/)
    end

    it "redacts passwords in messages" do
      expect(described_class.redact("postgres://app:s3cret@db.example/app")).to eq "postgres://app:***@db.example/app"
      expect(described_class.redact("sqlite:///tmp/x.db")).to eq "sqlite:///tmp/x.db"
    end
  end

  describe "the executable" do
    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def wait_for(port, seconds: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        TCPSocket.new("127.0.0.1", port).close
        return true
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        raise "editor did not start on port #{port}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.2
      end
    end

    it "migrates, seeds, serves on loopback, and rejects foreign Host headers" do
      Dir.mktmpdir do |dir|
        port = free_port
        log = File.join(dir, "editor.log")
        exe = File.expand_path("../exe/super_auth-editor", __dir__)
        env = { "SUPER_AUTH_DATABASE_URL" => "sqlite://#{File.join(dir, 'editor.db')}" }
        pid = Process.spawn(env, RbConfig.ruby, exe, "--migrate", "--seed", "--port", port.to_s, out: File::NULL, err: [log, "w"])
        begin
          wait_for(port)
          http = Net::HTTP.new("127.0.0.1", port)

          index = http.get("/")
          expect(index.code).to eq "200"
          expect(index.body).to include("graph editor")

          graph = JSON.parse(http.get("/api/graph").body)
          expect(graph["users"].size).to eq 10
          expect(graph["edges"].size).to eq 42

          foreign = http.get("/api/graph", { "Host" => "evil.example" })
          expect(foreign.code).to eq "403"

          created = http.post("/api/nodes/group", JSON.generate(name: "QA"), { "Content-Type" => "application/json" })
          expect(created.code).to eq "201"

          expect(File.read(log)).to include("no authentication")
        ensure
          Process.kill("INT", pid)
          Process.wait(pid)
        end
      end
    end

    it "aborts with a clear message when the URL is missing" do
      exe = File.expand_path("../exe/super_auth-editor", __dir__)
      out, status = Open3.capture2e({ "SUPER_AUTH_DATABASE_URL" => nil }, RbConfig.ruby, exe)
      expect(status.exitstatus).to eq 1
      expect(out).to include("SUPER_AUTH_DATABASE_URL")
    end
  end

  describe "packaging" do
    it "ships the editor and the executable, and nothing from spec/, bin/ or editor/" do
      gemspec = Gem::Specification.load(File.expand_path("../super_auth.gemspec", __dir__))
      expect(gemspec.executables).to eq ["super_auth-editor"]
      expect(gemspec.files).to include("lib/super_auth/editor.rb", "lib/super_auth/editor/index.html",
                                       "lib/super_auth/editor/seed.rb", "lib/super_auth/editor/cli.rb")
      expect(gemspec.files.grep(%r{\A(?:editor|bin|spec)/})).to be_empty
      expect(gemspec.runtime_dependencies.map(&:name)).to eq ["sequel"]
    end
  end
end
