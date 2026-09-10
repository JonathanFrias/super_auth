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

  # Wrap request work in SuperAuth.as(current_user) { ... } — in an
  # around_action, and around jobs — so the ByCurrentUser scope has a user.
  #
  # Postgres row-level security is optional and off until you ask for it:
  #   rails generate super_auth:rls Model ...
  # Once that migration has run, the same SuperAuth.as call also asserts the
  # identity the policies read, so turning it on costs no application change.
end
