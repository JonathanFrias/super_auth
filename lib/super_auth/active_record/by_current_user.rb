module SuperAuth::ActiveRecord::ByCurrentUser
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
        if SuperAuth.current_user.is_a?(SuperAuth::ActiveRecord::User)
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
          # Per-record authorization: filter to specific records the user can access.
          where(
            id: SuperAuth::ActiveRecord::Authorization
                .where(**user_where, resource_external_type: resource_type)
                .where.not(resource_external_id: nil)
                .select(:resource_external_id))
        end
      end
    end
  end

  module ClassMethods
  end
end
