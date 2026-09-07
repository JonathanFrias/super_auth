namespace :super_auth do
  desc "Run the super_auth database migrations"
  task migrate: :environment do
    raise "You must define SUPER_AUTH_DATABASE_URL in your environment for this to work" if ENV['SUPER_AUTH_DATABASE_URL'].nil? || ENV['SUPER_AUTH_DATABASE_URL'].empty?
    SuperAuth.install_migrations
    puts "Done"
  end

  namespace :labels do
    desc "Re-derive super_auth_resources.super_auth_label from the application records"
    task backfill: :environment do
      SuperAuth.load
      backfill = lambda do
        changed = 0
        SuperAuth::ActiveRecord::Resource.where.not(external_id: nil).find_each do |resource|
          before = resource.super_auth_label
          resource.refresh_label!
          changed += 1 if resource.super_auth_label != before
        end
        changed
      end

      # The application tables this reads are the ones RLS protects, so a run
      # with no identity derives nil for exactly the rows that matter most and
      # then reports success. Assert the system identity where RLS is
      # installed; where it is not, there is nothing to assert.
      changed =
        if SuperAuth::RLS.installed?
          SuperAuth.as(SuperAuth::ActiveRecord::User.system) { backfill.call }
        else
          backfill.call
        end
      puts "Labelled #{changed} resources"
    end
  end

  task :rollback => :environment do
    raise "You must define SUPER_AUTH_DATABASE_URL in your environment for this to work" if ENV['SUPER_AUTH_DATABASE_URL'].nil? || ENV['SUPER_AUTH_DATABASE_URL'].empty?
    SuperAuth.uninstall_migrations
    puts "Done"
  end
end
