# frozen_string_literal: true

# See https://blog.pawelpokrywka.com/p/gem-with-zeitwerk-as-development-only-dependency
module ::SuperAuth
  AUTOLOADERS = []
end

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
  gem "sqlite3"
  gem "activerecord"
end
