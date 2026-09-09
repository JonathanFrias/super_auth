module SuperAuth
  if defined? Rails::Engine
    class Engine < Rails::Engine
      isolate_namespace SuperAuth

      # Use ActiveRecord migrations when in a Rails environment
      if defined?(ActiveRecord)
        config.paths['db/migrate'] = 'db/migrate_activerecord'
      end
    end
  end

  if defined? Rails::Railtie
    class Railtie < Rails::Railtie
      rake_tasks do
        load "tasks/super_auth_tasks.rake"
      end

      # Rails 7.1+ keeps one deprecator per library and applies
      # config.active_support.deprecation / report_deprecations to each of
      # them in the active_support.deprecation_behavior initializer, which
      # runs after load_environment_config — so registration has to come
      # before that, as Rails' own railties do.
      initializer "super_auth.deprecator", before: :load_environment_config do |app|
        app.deprecators[:super_auth] = SuperAuth.deprecator if app.respond_to?(:deprecators)
      end

      initializer "super_auth.initialize" do
        if defined?(ActiveRecord) && defined?(ActiveRecord::Base)
          SuperAuth.db
          begin
            SuperAuth.load
          rescue Sequel::DatabaseError => e
            # Tables don't exist yet (e.g., before migrations are run)
            # This is OK - models will be loaded when needed
            Rails.logger.debug "SuperAuth Sequel models not loaded: #{e.message}" if defined?(Rails.logger)
          end
          require "super_auth/active_record"
        elsif defined?(Sequel) && Sequel.const_defined?("Model")
          SuperAuth.db
          SuperAuth.load
        end
      end
    end
  else
    class Railtie
    end
  end
end
