module SuperAuth::ActiveRecord::ByCurrentUser
  def self.included(base)
    base.has_many :super_auth_authorizations

    base.send(:default_scope, **{all_queries: true}) do
      raise "SuperAuth.current_user not set" if SuperAuth.current_user.blank?

      if SuperAuth.current_user.system?
        self
      else
        where(id: SuperAuth::ActiveRecord::Authorization.where(super_auth_user_id: SuperAuth.current_user.id).select(:resource_id))
      end
    end
  end

  def system? = false

  module ClassMethods
  end

end
