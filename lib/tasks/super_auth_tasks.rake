namespace :super_auth do
  desc "Run the super_auth database migrations"
  task migrate: :environment do
    raise "You must define SUPER_AUTH_DATABASE_URL in your environment for this to work" if ENV['SUPER_AUTH_DATABASE_URL'].nil? || ENV['SUPER_AUTH_DATABASE_URL'].empty?
    SuperAuth.install_migrations
    puts "Done"
  end

  task :rollback => :environment do
    raise "You must define SUPER_AUTH_DATABASE_URL in your environment for this to work" if ENV['SUPER_AUTH_DATABASE_URL'].nil? || ENV['SUPER_AUTH_DATABASE_URL'].empty?
    SuperAuth.uninstall_migrations
    puts "Done"
  end
end
