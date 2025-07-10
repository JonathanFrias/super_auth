module SuperAuth::ActiveRecord::ByCurrentUser
  def self.included(base)
    base.has_many :super_auth_authorizations

    base.send(:default_scope, **{all_queries: true}) do
      raise "SuperAuth.current_user not set" if SuperAuth.current_user.blank?

      if SuperAuth.current_user.respond_to?(:system?) && SuperAuth.current_user.system?
        self
      else
        user_where =
        if SuperAuth.current_user.is_a?(SuperAuth::ActiveRecord::User)
          { user_id: SuperAuth.current_user.id }
        else
          { user_external_id: SuperAuth.current_user.id, user_external_type: SuperAuth.current_user.class.name }
        end

        resource_where =
        if try(:id)
          { resource_external_id: self.id, resource_external_type: self.class.name }
        else
          { resource_external_type: self.model.name }
        end

        # Important:
        # We use a subquery here instead of a inner join because we don't want
        # to potentially affect break on queries issue count queries in their app.
        where(
          id: SuperAuth::ActiveRecord::Authorization
              .where(**user_where, **resource_where)
              .select(:resource_id))
      end
    end
  end

  module ClassMethods
  end

end
