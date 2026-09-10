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
  # numbering. The SQL lives in SuperAuth::TreeGuard, which a host also calls
  # from its test setup: db/schema.rb cannot carry a trigger.
  up do
    SuperAuth::TreeGuard.install(db: self)
  end

  down do
    SuperAuth::TreeGuard.remove(db: self)
  end
end
