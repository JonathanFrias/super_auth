require 'rails/generators'
require 'rails/generators/active_record'

module SuperAuth
  module Generators
    class RlsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      # The model class names typed on the command line, verbatim:
      # `rails g super_auth:rls Document Invoice` => ["Document", "Invoice"]
      argument :model_names, type: :array, banner: "Model Model ..."

      desc "Creates a migration enabling Postgres row-level security for the given models"

      def create_migration_file
        migration_template 'migration.rb.erb', 'db/migrate/enable_super_auth_rls.rb'
      end
    end
  end
end
