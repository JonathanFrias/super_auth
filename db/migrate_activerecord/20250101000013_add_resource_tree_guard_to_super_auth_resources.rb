class AddResourceTreeGuardToSuperAuthResources < ActiveRecord::Migration[7.0]
  # Mirrors db/migrate/13_add_resource_tree_guard.rb, which says why: a
  # parent_id cycle silently widens grants, the models and compile! refuse
  # it, and this trigger refuses it for writes that go around them. Postgres
  # only; a no-op elsewhere. The SQL lives in SuperAuth::TreeGuard so a host
  # can install it from its test setup as well: db/schema.rb cannot carry a
  # trigger, so a test database built from it has none.
  def up
    SuperAuth::TreeGuard.install(db: SuperAuth.db)
  end

  def down
    SuperAuth::TreeGuard.remove(db: SuperAuth.db)
  end
end
