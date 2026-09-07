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

  # Column type for the external id columns (users.external_id,
  # resources.external_id and their copies on authorizations). Set it to your
  # application's primary key type (:bigint, :uuid, :string, ...) BEFORE
  # running the super_auth migrations — the columns are then created with the
  # matching type and every comparison against your tables' pks is natively
  # typed, with no casting anywhere. Default :string.
  def self.external_id_type
    @external_id_type || :string
  end

  def self.external_id_type=(type)
    @external_id_type = type
  end

  # Sequel migrations take the Ruby String class for varchar; anything else
  # passes through as the literal database type name.
  def self.sequel_external_id_type
    external_id_type == :string ? String : external_id_type
  end

  # The human name of the application record behind a node, by convention
  # rather than configuration: a model says it explicitly with
  # `super_auth_label`, otherwise `name` then `title` are tried, and a model
  # with none of them has no label. This is also the name of the column the
  # derivation is stored in, since `label` is a name applications want for
  # themselves. Deliberately never `to_s` — the label sits where the editor
  # otherwise renders `Type#id`, and "#<Claim:0x000055…>" is worse than the id
  # it would replace.
  def self.label_for(record)
    %i[super_auth_label name title].each do |method|
      next unless record.respond_to?(method)
      value = record.public_send(method)
      return value.to_s unless value.nil? || value.to_s.empty?
    end
    nil
  end

  def self.load
    require "super_auth/authorization"
    require "super_auth/edge"
    require "super_auth/nestable"
    require "super_auth/group"
    require "super_auth/permission"
    require "super_auth/railtie"
    require "super_auth/resource"
    require "super_auth/rls"
    require "super_auth/role"
    require "super_auth/user"
    require "super_auth/active_record" if defined?(ActiveRecord::Base)
  end

  def self.install_migrations
    Sequel.extension :migration
    require "pathname"
    path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    Sequel::Migrator.run(SuperAuth.db, path)
    refresh_model_schemas
  end

  # Both ORMs cache column types per model class; after (re)installing the
  # migrations those caches can describe a previous schema (e.g. a different
  # external_id_type) and silently miscast assigned values.
  def self.refresh_model_schemas
    models = %w[User Group Permission Role Resource Edge Authorization]
    if defined?(SuperAuth::ActiveRecord::User)
      models.each do |name|
        SuperAuth::ActiveRecord.const_get(name).reset_column_information
      end
    end
    if defined?(SuperAuth::User) && SuperAuth::User.respond_to?(:set_dataset)
      models.each do |name|
        model = SuperAuth.const_get(name)
        model.set_dataset(model.dataset)
      end
    end
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

  # Run the block as `user` in both layers: SuperAuth.current_user, which the
  # ByCurrentUser scope reads, and the database identity the RLS policies read
  # (see SuperAuth::RLS.as). Both are restored on the way out, whether the
  # block returns, raises, or was nested inside another `as`. Passing nil runs
  # the block with no user in either layer. Postgres only, since the database
  # half is. Keyword options (auto_savepoint:, ...) go to SuperAuth::RLS.as.
  # current_user is assigned inside the transaction, after the database
  # identity, so an application that hooks the writer to re-assert does so on
  # the connection that holds the transaction.
  def self.as(user, db: SuperAuth.db, **options)
    previous = current_user
    SuperAuth::RLS.as(user, db: db, **options) do
      self.current_user = user
      yield
    end
  ensure
    self.current_user = previous
  end

  # Both user models are internal: their id is the user_id that the policies
  # and ByCurrentUser match on. Anything else is an application object,
  # matched by id and class name.
  def self.internal_user?(user)
    (defined?(SuperAuth::ActiveRecord::User) && user.is_a?(SuperAuth::ActiveRecord::User)) ||
      (defined?(SuperAuth::User) && user.is_a?(SuperAuth::User))
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

      # Walk the ancestor chain so adapter subclasses (e.g. PostGIS, Makara)
      # are recognized as their parent adapter type.
      adapter_ancestors = ::ActiveRecord::Base.adapter_class.ancestors.map(&:to_s)
      if adapter_ancestors.include?("ActiveRecord::ConnectionAdapters::SQLite3Adapter")
        SuperAuth.db = Sequel.sqlite(**extensions)
      elsif adapter_ancestors.include?("ActiveRecord::ConnectionAdapters::PostgreSQLAdapter")
        SuperAuth.db = Sequel.postgres(**extensions)
      elsif adapter_ancestors.include?("ActiveRecord::ConnectionAdapters::Mysql2Adapter")
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

require "super_auth/rls"
require "super_auth/railtie" if defined?(Rails::Railtie)
