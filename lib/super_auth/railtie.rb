module SuperAuth
  if defined? Rails::Railtie
    class Railtie < Rails::Railtie
      rake_tasks do
        load "tasks/super_auth_tasks.rake"
      end
    end
  else
    class Railtie
    end
  end
end
