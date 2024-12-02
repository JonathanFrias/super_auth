# frozen_string_literal: true

require_relative "super_auth/version"

if defined? SuperAuth::AUTOLOADERS
  require 'zeitwerk'
  SuperAuth::AUTOLOADERS << Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/basic_loader.rb")
    loader.setup
  end
end

require 'sequel'

ENV["SUPER_AUTH_LOG_LEVEL"] = 'debug'
require 'logger'
logger = Logger.new(STDOUT)

Sequel::Model.plugin :timestamps, update_on_create: true
if !ENV['SUPER_AUTH_DATABASE_URL'].nil? && !ENV['SUPER_AUTH_DATABASE_URL'].empty?
  Sequel::Model.db = Sequel.connect(ENV['SUPER_AUTH_DATABASE_URL'], logger: logger)
else
  logger.warn "SUPER_AUTH_DATABASE_URL not set, using sqlite in memory database."
  Sequel::Model.db = Sequel.sqlite(logger: logger)
end
Sequel::Model.default_association_options = {:class_namespace=>'SuperAuth'}

# I don't love this, but I don't know how to do it better
unless Sequel::Model.db.table_exists?(:super_auth_edges)
  Sequel.extension :migration
  path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
  Sequel::Migrator.run(Sequel::Model.db, path)
end
require 'basic_loader' unless defined?(SuperAuth::AUTOLOADERS)


module SuperAuth
  class Error < StandardError; end
end

require "super_auth/railtie" if defined?(Rails::Railtie)
