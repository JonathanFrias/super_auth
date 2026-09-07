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
  def self.included(base)
    base.send(:default_scope, **{all_queries: true}) do
      if SuperAuth.current_user.blank?
        raise SuperAuth::Error, "SuperAuth.current_user not set" if SuperAuth.missing_user_behavior == :raise
        next none
      end

      if SuperAuth.current_user.respond_to?(:system?) && SuperAuth.current_user.system?
        self
      else
        user_where =
        if SuperAuth.internal_user?(SuperAuth.current_user)
          { user_id: SuperAuth.current_user.id }
        else
          { user_external_id: SuperAuth.current_user.id, user_external_type: SuperAuth.current_user.class.name }
        end

        resource_type = self.model.name

        # Type-level authorization (resource_external_id IS NULL) acts as wildcard:
        # user has access to ALL records of this type (e.g., admin with ADMIN_ACCESS).
        type_level = SuperAuth::ActiveRecord::Authorization
          .where(**user_where, resource_external_type: resource_type, resource_external_id: nil)

        if type_level.exists?
          self
        else
          # Per-record authorization: filter to specific records the user can
          # access. No type handling here: the external id columns are created
          # with the app's pk type (SuperAuth.external_id_type at install
          # time), so the comparison is natively typed.
          where(
            id: SuperAuth::ActiveRecord::Authorization
                .where(**user_where, resource_external_type: resource_type)
                .where.not(resource_external_id: nil)
                .select(:resource_external_id))
        end
      end
    end
  end
end
