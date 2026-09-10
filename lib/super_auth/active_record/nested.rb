# The tree safety SuperAuth::Nestable gives the Sequel models, for the three
# ActiveRecord twins that nest: a node may not be its own parent nor sit
# under one of its own descendants (either closes a parent_id cycle, and a
# cycle silently makes every node in it an ancestor of every other), and
# destroying a node takes its compiled rows and its edges with it. The
# ancestor walk runs through the Sequel twin on this connection
# (sequel-activerecord_connection), so it sees the open transaction. Children
# of a destroyed node are not touched: the foreign key refuses to orphan
# them, and re-rooting or deleting them is the caller's decision.
module SuperAuth::ActiveRecord::Nested
  def self.included(base)
    base.validate :parent_outside_own_subtree
    base.before_destroy :purge_grants
  end

  private

  # SuperAuth::ActiveRecord::Group -> SuperAuth::Group. Through base_class,
  # because a host subclasses these models to add scopes and callbacks and
  # the twin is the gem's: on the concrete name, Module#const_get falls
  # through to Object and returns the host's own class, which has neither
  # ancestor_pairs nor singularize, so every re-parent and every destroy
  # through a subclass raised NoMethodError.
  def sequel_twin
    SuperAuth.const_get(self.class.base_class.name.split("::").last)
  end

  def parent_outside_own_subtree
    return if parent_id.nil? || !will_save_change_to_attribute?(:parent_id)

    if parent_id == id
      errors.add(:parent_id, "cannot be the node itself")
    elsif persisted? && sequel_twin.ancestor_pairs(of: [parent_id]).where(ancestor_id: id).count > 0
      errors.add(:parent_id, "is inside the node's own subtree, which would close a cycle")
    end
  end

  def purge_grants
    column = :"#{sequel_twin.singularize}_id"
    SuperAuth::ActiveRecord::Authorization.where(column => id).delete_all
    SuperAuth::ActiveRecord::Edge.where(column => id).delete_all
  end
end
