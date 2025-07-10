module SuperAuth
  if defined? Rails::Railtie
    class Railtie < Rails::Railtie
      rake_tasks do
        load "tasks/super_auth_tasks.rake"
      end

      initializer "super_auth.initialize" do
        if defined?(Sequel) && Sequel.const_defined?("Model")
          require 'super_auth/authorization'
          require 'super_auth/edge'
          require 'super_auth/nestable'
          require 'super_auth/group'
          require 'super_auth/permission'
          require 'super_auth/resource'
          require 'super_auth/role'
          require 'super_auth/user'
        elsif defined?(ActiveRecord)
          require 'super_auth/active_record'
          require 'super_auth/active_record/authorization'
          require 'super_auth/active_record/edge'
          require 'super_auth/active_record/group'
          require 'super_auth/active_record/permission'
          require 'super_auth/active_record/resource'
          require 'super_auth/active_record/role'
          require 'super_auth/active_record/user'
          # SuperAuth::Authorization = SuperAuth::ActiveRecord::Authorization
          # SuperAuth::Edge = SuperAuth::ActiveRecord::Edge
          # SuperAuth::Group = SuperAuth::ActiveRecord::Group
          # SuperAuth::Permission = SuperAuth::ActiveRecord::Permission
          # SuperAuth::Resource = SuperAuth::ActiveRecord::Resource
          # SuperAuth::User = SuperAuth::ActiveRecord::User
          # SuperAuth::Role = SuperAuth::ActiveRecord::Role
        end
      end
    end
  else
    class Railtie
    end
  end
end
