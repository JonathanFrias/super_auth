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
  puts "Warning: SUPER_AUTH_DATABASE_URL not set, using in memory database"
  Sequel::Model.db = Sequel.sqlite(logger: logger)
  Sequel.extension :migration
  Sequel::Migrator.run(Sequel::Model.db, "db/migrate")
end
Sequel::Model.default_association_options = {:class_namespace=>'SuperAuth'}

require 'basic_loader' unless defined?(SuperAuth::AUTOLOADERS)

module SuperAuth
  class Error < StandardError; end
end
