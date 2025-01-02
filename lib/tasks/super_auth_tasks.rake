namespace :super_auth do
  desc "Run the super_auth database migrations"
  task migrate: :environment do
    SuperAuth.install_migrations
  end
end
