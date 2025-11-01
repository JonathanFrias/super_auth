require_relative "super_auth/version"
require "sequel"

module SuperAuth
  class Error < StandardError; end

  def self.setup
    yield self if block_given?
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
    @current_user = user
  end

  def self.current_user
    @current_user
  end

  def self.db
    return @db if !@db.nil?

    if !Gem::Specification.find_all_by_name("activerecord").empty?
      require "active_record"

      if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty? && ::ActiveRecord::Base.connected?
        puts "Already connected to database, ignoring specified ENV SUPER_AUTH_DATABASE_URL."
      elsif !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
        ::ActiveRecord::Base.establish_connection(ENV['SUPER_AUTH_DATABASE_URL'])
      else
        puts "ENV SUPER_AUTH_DATABASE_URL not set, using sqlite."
        ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      end

      extensions = Gem::Specification.find_all_by_name("sequel-activerecord_connection").any? ? { extensions: :activerecord_connection } : {}

      case ::ActiveRecord::Base.adapter_class.to_s
      when "ActiveRecord::ConnectionAdapters::SQLite3Adapter"
        SuperAuth.db = Sequel.sqlite(**extensions)
      when "ActiveRecord::ConnectionAdapters::PostgreSQLAdapter"
        SuperAuth.db = Sequel.postgres(**extensions)
      when "ActiveRecord::ConnectionAdapters::Mysql2Adapter"
        SuperAuth.db = Sequel.mysql2(**extensions)
      else
        puts "Unknown adapter: #{::ActiveRecord::Base.adapter_class}"
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
        puts "ENV SUPER_AUTH_DATABASE_URL not set, using sqlite."
        SuperAuth.db = Sequel.sqlite(**logger)
      end
    end
  end

  def self.db=(db)
    @db = db
  end
end

require "super_auth/railtie" if defined?(Rails::Railtie)
