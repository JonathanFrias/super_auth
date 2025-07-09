require "spec_helper"

RSpec.describe SuperAuth do

  around do |example|
    # TODO: Fix this. This sort of test setup works, but it should be consolidated betterer.
    ENV['SUPER_AUTH_DATABASE_URL'], orig = 'sqlite://./tmp/test.db', ENV['SUPER_AUTH_DATABASE_URL']
    # ENV["SUPER_AUTH_LOG_LEVEL"] = "debug"
    SuperAuth.set_db
    SuperAuth.install_migrations
    SuperAuth.db.run "create table if not exists resources (id integer primary key, name varchar(255))"
    SuperAuth::ActiveRecord::User.itself # Loads if it it hasn't been loaded yet. TODO: Make this the normal ApplicationRecord rails style
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: './tmp/test.db')
    example.run
    ENV['SUPER_AUTH_DATABASE_URL'] = orig
  end

  let(:resource_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = :resources
      include SuperAuth::ActiveRecord::ByCurrentUser

      def self.name
        "Resource"
      end

      def system?
        false
      end
    end
  end

  context "when not logged in" do
    before do
      SuperAuth.current_user = nil
    end

    it "errors" do
      expect {
        resource_class.limit(10).to_sql
      }.to raise_error("SuperAuth.current_user not set")
    end
  end

  context "when logged in" do
    before do
      SuperAuth.current_user = SuperAuth::ActiveRecord::User.create(name: "name")
    end

    it "Can load the activerecord module" do
      expect(resource_class.limit(10).to_sql).to eq %Q[SELECT "resources".* FROM "resources" WHERE "resources"."id" IN (SELECT "super_auth_authorizations"."resource_id" FROM "super_auth_authorizations" WHERE "super_auth_authorizations"."super_auth_user_id" = #{SuperAuth.current_user.id}) LIMIT 10]
    end

    it "authenticates via the normal way" do
    end
  end
end
