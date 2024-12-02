namespace :super_auth do
  desc "Run the super_auth database migrations"
  task migrate: :environment do
    # TODO: Make this work properly without auto applying migrations, which is silly
    #
    # raise "ENV variable SUPER_AUTH_DATABASE_URL is not set" if ENV['SUPER_AUTH_DATABASE_URL'].nil? || ENV['SUPER_AUTH_DATABASE_URL'].empty?
    # Sequel::Model.db = Sequel.connect(ENV['SUPER_AUTH_DATABASE_URL'])
    # Sequel.extension :migration
    # binding.irb
    # path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    # Sequel::Migrator.run(Sequel::Model.db, path)
  end
end
