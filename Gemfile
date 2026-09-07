source "https://rubygems.org"
# Specify your gem's dependencies in super_auth.gemspec
gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "zeitwerk", "~> 2.6"
gem "sequel"

group :development, :test do
  gem "pry"
  gem "pg"
  gem "mysql2"
  gem "sqlite3"
  gem "activerecord"
  gem "sequel-activerecord_connection"
  gem "after_commit_everywhere"
  # Rack::MockRequest and Rack::Lint for the editor specs, and a server for
  # exe/super_auth-editor. The gem itself depends on none of them.
  gem "rack"
  gem "rackup"
  gem "webrick"
end
