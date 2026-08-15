# SuperAuth Initializer
# The SuperAuth Railtie automatically connects to your database and loads all
# models on boot. Use this file for any additional configuration.
#
SuperAuth.setup do |config|
  # Column type for external id columns, created when the migrations run.
  # Match your application's primary key type (:bigint, :uuid, :string, ...)
  # so comparisons against your tables' pks are natively typed. Rails
  # defaults to bigint pks. Must be set before running super_auth migrations.
  config.external_id_type = :bigint

  # Raise an error when a query runs without a current user set.
  # Default is :none (returns empty results silently).
  # config.missing_user_behavior = :raise

  # Mirror current_user into Postgres session settings so row-level
  # security policies (rails generate super_auth:rls Model ...) enforce
  # authorization inside the database. Postgres only.
  # config.rls = true
end
