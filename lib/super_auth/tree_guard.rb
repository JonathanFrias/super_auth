module SuperAuth
  # The database-side cycle guard on super_auth_resources.parent_id: a
  # Postgres trigger refusing a node as its own parent, or a parent inside
  # the node's own subtree. A parent_id cycle is a security defect once
  # resources carry tenancy — every node in a cycle is an ancestor of every
  # other, so a grant on any of them reaches all their subtrees, and the
  # walks terminate on a cycle (UNION), so nothing fails loudly. The models
  # refuse the shape and compile! refuses to run on it; the trigger is the
  # line for writes that go around both: a raw UPDATE, a data migration,
  # another language.
  #
  # Migration 13 installs it, and this module exists because a migration is
  # not enough to deliver a trigger to where hosts test: Rails' default
  # schema_format is :ruby, db/schema.rb cannot carry a function or a
  # trigger, and db:test:prepare loads schema.rb — so on such a host the
  # guard is present in development and production and absent from the test
  # database, where a test asserting "cycles cannot happen" passes for the
  # wrong reason. Call `install` from the test setup, beside
  # SuperAuth::RLS.enable, which schema.rb loses for the same reason.
  #
  # Postgres only. SQLite and MySQL each have triggers in a dialect of their
  # own; the model and compile guards hold there, and a second and third
  # implementation is not worth carrying. On those, every method is a no-op
  # that answers false.
  module TreeGuard
    NAME = "super_auth_resources_tree_guard".freeze

    FUNCTION_SQL = <<~SQL.freeze
      CREATE OR REPLACE FUNCTION #{NAME}() RETURNS trigger LANGUAGE plpgsql AS $$
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

    # The walk goes UP from the new parent with UNION, so a cycle already in
    # the table that does not include the row terminates instead of looping.
    # WHEN keeps the trigger off every root write, which is most of them.
    TRIGGER_SQL = <<~SQL.freeze
      CREATE TRIGGER #{NAME}
        BEFORE INSERT OR UPDATE OF parent_id ON super_auth_resources
        FOR EACH ROW WHEN (NEW.parent_id IS NOT NULL)
        EXECUTE FUNCTION #{NAME}()
    SQL

    class << self
      # Installs, or reinstalls, the function and the trigger. Idempotent;
      # true when installed, false where the database has no such thing.
      def install(db: SuperAuth.db)
        return false unless postgres?(db)

        db.run FUNCTION_SQL
        db.run "DROP TRIGGER IF EXISTS #{NAME} ON super_auth_resources"
        db.run TRIGGER_SQL
        true
      end

      def remove(db: SuperAuth.db)
        return false unless postgres?(db)

        db.run "DROP TRIGGER IF EXISTS #{NAME} ON super_auth_resources"
        db.run "DROP FUNCTION IF EXISTS #{NAME}()"
        true
      end

      # Whether the trigger is on the table now — the question a test helper
      # or a health check asks of a database that may have been built from
      # schema.rb.
      def installed?(db: SuperAuth.db)
        return false unless postgres?(db)

        db.fetch(
          "SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid " \
          "WHERE c.relname = 'super_auth_resources' AND t.tgname = ? AND NOT t.tgisinternal", NAME
        ).any?
      end

      private

      def postgres?(db)
        db.database_type == :postgres
      end
    end
  end
end
