Sequel.migration do
  # A parent_id cycle in super_auth_resources is a security defect, not
  # untidiness: every node in a cycle is an ancestor of every other, so a
  # grant on any of them reaches all of their subtrees, and the walks
  # terminate on a cycle (UNION), so nothing fails loudly. The models refuse
  # the shape (SuperAuth::Nestable validate) and compile! refuses to run on it
  # (assert_acyclic!). This trigger is the third line, for writes that go
  # around both — a raw UPDATE, a data migration, another language — and
  # refuses them at the row, with the same two rules: a node is not its own
  # parent, and its new parent is not inside its own subtree. The walk goes
  # UP from the new parent with UNION, so a cycle already in the table that
  # does not include the row terminates instead of looping.
  #
  # Postgres only. SQLite and MySQL both have triggers, each in a dialect of
  # its own with its own limits on what a trigger body may do, and the model
  # and compile guards already hold there; a second and third implementation
  # of the same check is not worth what it costs to carry. On those two this
  # migration does nothing, and says so here rather than in a gap in the
  # numbering.
  up do
    if database_type == :postgres
      run <<~SQL
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
      run "DROP TRIGGER IF EXISTS super_auth_resources_tree_guard ON super_auth_resources"
      run <<~SQL
        CREATE TRIGGER super_auth_resources_tree_guard
          BEFORE INSERT OR UPDATE OF parent_id ON super_auth_resources
          FOR EACH ROW WHEN (NEW.parent_id IS NOT NULL)
          EXECUTE FUNCTION super_auth_resources_tree_guard()
      SQL
    end
  end

  down do
    if database_type == :postgres
      run "DROP TRIGGER IF EXISTS super_auth_resources_tree_guard ON super_auth_resources"
      run "DROP FUNCTION IF EXISTS super_auth_resources_tree_guard()"
    end
  end
end
