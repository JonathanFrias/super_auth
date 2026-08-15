module SuperAuth
  if defined? Rails::Engine
    class Engine < Rails::Engine
      isolate_namespace SuperAuth

      config.paths.add 'app/controllers', eager_load: true

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
