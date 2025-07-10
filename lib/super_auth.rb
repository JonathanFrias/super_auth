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

  def self.set_db
    logger =
      if defined?(Rails) && ENV["SUPER_AUTH_LOG_LEVEL"] == "debug"
        Rails.logger
      elsif ENV["SUPER_AUTH_LOG_LEVEL"] == "debug"
        require "logger"
        logger = Logger.new(STDOUT)
      else
        nil
      end

    if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
      SuperAuth.db = Sequel.connect(ENV['SUPER_AUTH_DATABASE_URL'], logger: logger)
    else
      puts "ENV SUPER_AUTH_DATABASE_URL not set, using sqlite."
      SuperAuth.db = Sequel.sqlite(logger: logger, database: "./tmp/test.db")
      install_migrations
    end
    Sequel::Model.default_association_options = {:class_namespace=>'SuperAuth'}
  end

  def self.install_migrations
    require "sequel"
    Sequel.extension :migration
    require "pathname"
    path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    Sequel::Migrator.run(SuperAuth.db, path)
  end

  def self.uninstall_migrations
    require "sequel"
    set_db
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

  def self.db=(db)
    @db = db
  end

  def self.db
    @db
  end
end

require "super_auth/railtie" if defined?(Rails::Railtie)
