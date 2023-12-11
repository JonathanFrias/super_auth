# frozen_string_literal: true

require "super_auth"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.before(:suite) do
    Sequel::Model.db = Sequel.sqlite
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
