require_relative "super_auth/version"

if defined? SuperAuth::AUTOLOADERS
  require 'zeitwerk'
  SuperAuth::AUTOLOADERS << Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/basic_loader.rb")
    loader.setup
  end
  require "sequel"
else
  require 'basic_loader'
end

module SuperAuth
  class Error < StandardError; end

  def self.setup
    yield self if block_given?
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

    if !Gem::Specification.find_by_name("activerecord").nil?
      require "active_record"

      if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty? && ::ActiveRecord::Base.connected?
        puts "Already connected to database, ignoring specified ENV SUPER_AUTH_DATABASE_URL."
      elsif !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
        ::ActiveRecord::Base.establish_connection(ENV['SUPER_AUTH_DATABASE_URL'])
      else
        puts "ENV SUPER_AUTH_DATABASE_URL not set, using sqlite."
        ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      end
      logger = ::ActiveRecord::Base.logger

      case ::ActiveRecord::Base.adapter_class.to_s
      when "ActiveRecord::ConnectionAdapters::SQLite3Adapter"
        SuperAuth.db = Sequel.sqlite(logger: logger, extensions: :activerecord_connection)
      when "ActiveRecord::ConnectionAdapters::PostgreSQLAdapter"
        SuperAuth.db = Sequel.postgres(logger: logger, extensions: :activerecord_connection)
      when "ActiveRecord::ConnectionAdapters::Mysql2Adapter"
        SuperAuth.db = Sequel.mysql2(logger: logger, extensions: :activerecord_connection)
      else
        puts "Unknown adapter: #{::ActiveRecord::Base.adapter_class}"
      end
    else
      if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
        SuperAuth.db = Sequel.connect(ENV['SUPER_AUTH_DATABASE_URL'], logger: logger)
      else
        puts "ENV SUPER_AUTH_DATABASE_URL not set, using sqlite."
        SuperAuth.db = Sequel.sqlite(logger: logger)
      end
    end
  end

  def self.db=(db)
    @db = db
  end
end

require "super_auth/railtie" if defined?(Rails::Railtie)
