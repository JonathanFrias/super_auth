class AddResourceTreeGuardToSuperAuthResources < ActiveRecord::Migration[7.0]
  # Mirrors db/migrate/13_add_resource_tree_guard.rb, which says why: a
  # parent_id cycle silently widens grants, the models and compile! refuse
  # it, and this trigger refuses it for writes that go around them. Postgres
  # only; a no-op elsewhere.
  def up
    return unless postgres?

    execute <<~SQL
      CREATE OR REPLACE FUNCTION super_auth_resources_tree_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.parent_id = NEW.id THEN
          RAISE EXCEPTION 'super_auth_resources: node % cannot be its own parent', NEW.id
            USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (
          WITH RECURSIVE ancestors(id, parent_id) AS (
            SELECT r.id, r.parent_id FROM super_auth_resources r WHERE r.id = NEW.parent_id
            UNION
            SELECT r.id, r.parent_id FROM super_auth_resources r JOIN ancestors a ON r.id = a.parent_id
          )
          SELECT 1 FROM ancestors WHERE ancestors.id = NEW.id
        ) THEN
          RAISE EXCEPTION 'super_auth_resources: parent_id % is inside the subtree of node %, which would close a cycle', NEW.parent_id, NEW.id
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END
      $$;
    SQL
    execute "DROP TRIGGER IF EXISTS super_auth_resources_tree_guard ON super_auth_resources"
    execute <<~SQL
      CREATE TRIGGER super_auth_resources_tree_guard
        BEFORE INSERT OR UPDATE OF parent_id ON super_auth_resources
        FOR EACH ROW WHEN (NEW.parent_id IS NOT NULL)
        EXECUTE FUNCTION super_auth_resources_tree_guard()
    SQL
  end

  def down
    return unless postgres?

    execute "DROP TRIGGER IF EXISTS super_auth_resources_tree_guard ON super_auth_resources"
    execute "DROP FUNCTION IF EXISTS super_auth_resources_tree_guard()"
  end

  private

  def postgres?
    connection.adapter_name.match?(/postg/i)
  end
end
