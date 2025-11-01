module DbHelper
  def db
    SuperAuth.db
  end

  def clear_super_auth_tables
    db[:super_auth_edges].delete
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  def connection_string
    ENV['SUPER_AUTH_DATABASE_URL']
  end

  def sqlite_memory_connection_string
  end

  def active_record_available?
    require "active_record"
    true
  rescue LoadError
    false
  end

  def install_migrations
    Sequel.extension :migration
    require "pathname"
    path = Pathname.new(__FILE__).parent.parent.join("db", "migrate")
    Sequel::Migrator.run(db, path)
  end
end
