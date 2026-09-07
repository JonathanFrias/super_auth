class SuperAuth::ActiveRecord::Resource < ActiveRecord::Base
  self.table_name = 'super_auth_resources'
  belongs_to :external, polymorphic: true, optional: true

  # `super_auth_label` is a stored snapshot of the application record's human
  # name, so the editor can render "Gulf War presumptive" instead of
  # Claim#3a00b6fa and `super_auth-editor` can do it against a bare
  # SUPER_AUTH_DATABASE_URL with no application loaded. It carries the prefix
  # for the same reason the opt-in method on the host's model does: `label` is
  # a name applications want for themselves.
  #
  # Deriving it here means a host that already syncs its resources gets labels
  # with no extra wiring; renames still need refresh_label!, since they do not
  # write this row.
  before_save :set_label, if: :external_id?

  # Re-derive the label after the application record is renamed. Hosts call it
  # from whatever already syncs the node; super_auth:labels:backfill calls it
  # for every row.
  def refresh_label!
    derived = derived_label
    update_column(:super_auth_label, derived) unless derived.nil?
  end

  private

  def set_label
    derived = derived_label
    self.super_auth_label = derived unless derived.nil?
  end

  # ponytail: a nil derivation never overwrites a stored label, in either
  # path, and never fails the save. Three things derive nil and none of them
  # means "this record has no name": RLS makes the application record
  # unreadable without an asserted identity, external_type is a plain string
  # that can name a class this process has not loaded, and type-level rows
  # (external_id IS NULL) have no record to name at all. Writing nil for any
  # of them would turn "this label is stale" into data, which is the failure
  # this column exists to avoid.
  def derived_label
    SuperAuth.label_for(external)
  rescue NameError
    nil
  end
end
