require_relative "super_auth/version"
require "sequel"

module SuperAuth
  class Error < StandardError; end

  def self.setup
    yield self if block_given?
  end

  # Controls behavior when SuperAuth.current_user is blank in ByCurrentUser scope.
  # :none (default) — returns an empty result set silently
  # :raise — raises SuperAuth::Error
  def self.missing_user_behavior
    @missing_user_behavior || :none
  end

  def self.missing_user_behavior=(behavior)
    unless %i[none raise].include?(behavior)
      raise ArgumentError, "missing_user_behavior must be :none or :raise, got #{behavior.inspect}"
    end
    @missing_user_behavior = behavior
  end

  def self.load
    require "super_auth/authorization"
    require "super_auth/edge"
    require "super_auth/nestable"
    require "super_auth/group"
    require "super_auth/permission"
    require "super_auth/railtie"
    require "super_auth/resource"
    require "super_auth/role"
    require "super_auth/user"
    require "super_auth/active_record" if defined?(ActiveRecord::Base)
  end

  def self.install_migrations
    Sequel.extension :migration
    require "pathname"
    path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    Sequel::Migrator.run(SuperAuth.db, path)
  end

  def self.uninstall_migrations
    require "sequel"
    Sequel.extension :migration
    require "pathname"

    path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    db = SuperAuth.db

    Sequel::Migrator.run(db, path, target: 0)
  rescue => e
    raise Error, "Failed to uninstall migrations: #{e.message}"
  end

  def self.current_user=(user)
    Thread.current[:super_auth_current_user] = user
  end

  def self.current_user
    Thread.current[:super_auth_current_user]
  end

  def self.db
    return @db if !@db.nil?

    if !Gem::Specification.find_all_by_name("activerecord").empty?
      require "active_record"
      extensions = Gem::Specification.find_all_by_name("sequel-activerecord_connection").any? ? { extensions: :activerecord_connection } : {}

      if extensions.empty?
        warn "[SuperAuth] WARNING: Found ActiveRecord but could not find the gem 'sequel-activerecord_connection' installed. SuperAuth may not always work as expected."
      end

      begin
        ::ActiveRecord::Base.establish_connection
      rescue ActiveRecord::AdapterNotSpecified
        if defined?(Rails) && !Rails.env.local?
          raise Error, "SuperAuth could not find a database configuration. " \
            "Please configure ActiveRecord or set SUPER_AUTH_DATABASE_URL."
        end
        warn "[SuperAuth] WARNING: No database configured. Falling back to in-memory SQLite. " \
          "All authorization data will be lost on restart."
        ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      end

      case ::ActiveRecord::Base.adapter_class.to_s
      when "ActiveRecord::ConnectionAdapters::SQLite3Adapter"
        SuperAuth.db = Sequel.sqlite(**extensions)
      when "ActiveRecord::ConnectionAdapters::PostgreSQLAdapter"
        SuperAuth.db = Sequel.postgres(**extensions)
      when "ActiveRecord::ConnectionAdapters::Mysql2Adapter"
        SuperAuth.db = Sequel.mysql2(**extensions)
      else
        warn "[SuperAuth] WARNING: Unknown adapter: #{::ActiveRecord::Base.adapter_class}"
      end
    else
      logger =
      if defined?(Rails) && ENV["SUPER_AUTH_LOG_LEVEL"] == "debug"
        { logger: Rails.logger }
      elsif ENV["SUPER_AUTH_LOG_LEVEL"] == "debug"
        require "logger"
        { logger: Logger.new(STDOUT) }
      else
        {} # no logger
      end

      if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
        SuperAuth.db = Sequel.connect(ENV['SUPER_AUTH_DATABASE_URL'], **logger)
      else
        if defined?(Rails) && !Rails.env.local?
          raise Error, "SuperAuth could not find a database configuration. " \
            "Please set SUPER_AUTH_DATABASE_URL or configure ActiveRecord."
        end
        warn "[SuperAuth] WARNING: SUPER_AUTH_DATABASE_URL not set. Falling back to in-memory SQLite. " \
          "All authorization data will be lost on restart."
        SuperAuth.db = Sequel.sqlite(**logger)
      end
    end
  end

  def self.db=(db)
    @db = db
  end
end

require "super_auth/railtie" if defined?(Rails::Railtie)
