module SuperAuth::ActiveRecord::ByCurrentUser
  # Records are filtered to those the current user holds an authorization for,
  # keyed by the querying class's name. Because a subclass is its own resource
  # type, privileged methods can be placed on a subclass whose access must be
  # approved explicitly — a grant on the base class does not flow down:
  #
  #   class Resource < ApplicationRecord
  #     super_auth
  #
  #     class ResourceRestartPermission < Resource
  #       def restart!
  #         # dangerous restart operation
  #       end
  #     end
  #   end
  #
  # Resource::ResourceRestartPermission shares the base class's table and rows,
  # but loading it requires an authorization whose resource_external_type is
  # "Resource::ResourceRestartPermission" (edges to a SuperAuth::Resource
  # registered with that external_type). If you can't load the object, you
  # can't call the method.
  #
  # A parent step admits a row through a column holding another record's id,
  # the row's tenancy read off the row itself, so a grant on the organization
  # reaches every claim whose organization_id it is without a node per claim:
  #
  #   class Claim < ApplicationRecord
  #     super_auth parent: { column: :organization_id,
  #                          resource_type: %w[Organization::Member Organization::Admin] }
  #   end
  #
  # The steps are OR'd, never collapsed into the parent step alone: a
  # per-record grant admits a row whose parent column is NULL, and a parent
  # grant admits rows that have no node. A subclass inherits the declared
  # parents and is still keyed on its own name; re-declaring on the subclass
  # replaces its parents alone, on the one inherited default scope, since two
  # default scopes AND together and would deny every row the parent step
  # admits.
  def self.included(base)
    # The attributes mark a hierarchy that already carries the scope. A
    # second include, a subclass re-declaring or a host including the module
    # twice, would add a second default scope.
    return if base.respond_to?(:super_auth_reach)

    base.class_attribute :super_auth_reach, instance_writer: false
    base.class_attribute :super_auth_wildcard, instance_writer: false, default: true
    base.extend ClassMethods
    base.send(:default_scope, all_queries: true) do
      if SuperAuth.current_user.blank?
        raise SuperAuth::Error, "SuperAuth.current_user not set" if SuperAuth.missing_user_behavior == :raise
        next none
      end
      next self if SuperAuth.current_user.respond_to?(:system?) && SuperAuth.current_user.system?

      model.super_auth_preflight!
      held = SuperAuth::ActiveRecord::ByCurrentUser.held_by(SuperAuth.current_user)

      # Type-level authorization (resource_external_id IS NULL) acts as wildcard:
      # user has access to ALL records of this type (e.g., admin with ADMIN_ACCESS).
      if model.super_auth_wildcard && held.where(resource_external_type: model.name, resource_external_id: nil).exists?
        next self
      end

      # One IN-subquery per step of the reach, OR'd: the row's own id against
      # the class's own type, then each parent column against its types. No
      # type handling here: the external id columns are created with the
      # app's pk type (SuperAuth.external_id_type at install time), so the
      # comparison is natively typed. all_queries, so an instance's update,
      # destroy and reload carry the same OR.
      model.super_auth_effective_reach.map do |column, types|
        where(column => held.where(resource_external_type: types).where.not(resource_external_id: nil).select(:resource_external_id))
      end.reduce(:or)
    end
  end

  # The compiled rows `user` holds, matched the way compile! wrote them: a
  # SuperAuth user by user_id, an application user by its id and class name.
  def self.held_by(user)
    if SuperAuth.internal_user?(user)
      SuperAuth::ActiveRecord::Authorization.where(user_id: user.id)
    else
      SuperAuth::ActiveRecord::Authorization.where(user_external_id: user.id, user_external_type: user.class.name)
    end
  end

  # ActiveRecord already folds the widths of one storage class into one
  # abstract type (integer and bigint, varchar and char); text joins varchar
  # here because the database compares those two natively.
  def self.type_family(column)
    column.type == :text ? :string : column.type
  end

  module ClassMethods
    # The reach as this class queries it: the per-record step on its own
    # name, since a subclass is its own resource type, then the parent steps
    # it or its nearest declaring ancestor declared. Recomputed rather than
    # stored because the stored map's :id names the declaring class.
    def super_auth_effective_reach
      { id: [name] }.merge(super_auth_parents)
    end

    # The compiled rows admitting one row for the current user, each tagged
    # with the step it came through (:type_level, :id or the parent column),
    # the rows the scope's subqueries match; the compiled table alone no
    # longer answers who can see a row once a parent column takes part.
    # Empty when nothing admits it; [{ step: :system }] under the system
    # user, which bypasses the compiled table. The row is read unscoped,
    # since the question is usually asked about one the user cannot see.
    def super_auth_explain(record_or_id)
      user = SuperAuth.current_user
      if user.blank?
        raise SuperAuth::Error, "SuperAuth.current_user not set" if SuperAuth.missing_user_behavior == :raise
        return []
      end
      return [{ step: :system }] if user.respond_to?(:system?) && user.system?

      record = unscoped.find(record_or_id.is_a?(::ActiveRecord::Base) ? record_or_id.id : record_or_id)
      held = SuperAuth::ActiveRecord::ByCurrentUser.held_by(user)
      tag = ->(step, rows) { rows.map { |row| { step: step, **row.attributes.symbolize_keys } } }

      rows = []
      rows.concat tag.(:type_level, held.where(resource_external_type: name, resource_external_id: nil)) if super_auth_wildcard
      super_auth_effective_reach.each do |column, types|
        value = record[column]
        # A NULL column is reached by nothing: "col = NULL" is never true.
        next if value.nil?
        rows.concat tag.(column, held.where(resource_external_type: types, resource_external_id: value))
      end
      rows
    end

    # Each parent column must exist on the table and share
    # resource_external_id's type family. Checked on the first query rather
    # than at declaration so a process can boot before its migrations run,
    # and once per model, since the answer changes only with the schema.
    # Postgres refuses a mismatched comparison; MySQL coerces it silently and
    # admits whatever rows the cast happens to match, so the declaration is
    # refused here, naming both sides.
    def super_auth_preflight!
      return if @super_auth_preflight

      expected = SuperAuth::ActiveRecord::Authorization.columns_hash.fetch("resource_external_id")
      super_auth_parents.each_key do |column|
        actual = columns_hash[column.to_s]
        unless actual
          raise SuperAuth::Error, "#{name} declares parent column #{column}, which table #{table_name} does not have"
        end
        unless SuperAuth::ActiveRecord::ByCurrentUser.type_family(actual) == SuperAuth::ActiveRecord::ByCurrentUser.type_family(expected)
          raise SuperAuth::Error, "#{name}.#{column} is #{actual.sql_type} but super_auth_authorizations.resource_external_id is #{expected.sql_type}; " \
                                  "a parent column must have the type of SuperAuth.external_id_type, the type of the ids it holds"
        end
      end
      @super_auth_preflight = true
    end

    # The preflight's answer is column information, so it is dropped with it.
    def reset_column_information
      @super_auth_preflight = nil
      super
    end

    private

    # No macro call (the module included directly) declares no parents.
    def super_auth_parents
      super_auth_reach ? SuperAuth::Reach.parents(super_auth_reach) : {}
    end
  end
end
