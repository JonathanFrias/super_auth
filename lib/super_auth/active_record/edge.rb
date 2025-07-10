class SuperAuth::ActiveRecord::Edge < ActiveRecord::Base
  self.table_name = 'super_auth_edges'
  belongs_to :user, class_name: 'SuperAuth::ActiveRecord::User'
  belongs_to :group, class_name: 'SuperAuth::ActiveRecord::Group'
  belongs_to :permission, class_name: 'SuperAuth::ActiveRecord::Permission'
  belongs_to :role, class_name: 'SuperAuth::ActiveRecord::Role'
  belongs_to :resource, class_name: 'SuperAuth::ActiveRecord::Resource'

  def before_save
    @affected_users = SuperAuth::Authorization.where(user_id: user_id).distinct.select_map(:user_id) + [user_id]
  end

  def after_save
    SuperAuth::Authorization.db.transaction do
      SuperAuth::Authorization.where(user_id: @affected_users).delete
      SuperAuth::Authorization.multi_insert(
        SuperAuth::Edge.authorizations.where(user_id: @affected_users)
        .to_a
      )
    end
  end

  class << self
    def authorizations
      from(
        SuperAuth::Edge.authorizations.sql
      )
    end

    def users_resources
      SuperAuth::ActiveRecord::Edge.from(
        %Q[(#{SuperAuth::Edge.users_resources.sql}) as super_auth_edges]
      )
    end

    def users_groups_roles_permissions_resources
      SuperAuth::ActiveRecord::Edge.from(
        %Q[(#{SuperAuth::Edge.users_groups_roles_permissions_resources.sql}) as super_auth_edges]
      )
    end

    def users_groups_permissions_resources
      SuperAuth::ActiveRecord::Edge.from(
        %Q[(#{SuperAuth::Edge.users_groups_permissions_resources.sql}) as super_auth_edges]
      )
    end

    def users_roles_permissions_resources
      SuperAuth::ActiveRecord::Edge.from(
        %Q[(#{SuperAuth::Edge.users_roles_permissions_resources.sql}) as super_auth_edges]
      )
    end

    def users_permissions_resources
      SuperAuth::ActiveRecord::Edge.from(
        %Q[(#{SuperAuth::Edge.users_permissions_resources.sql}) as super_auth_edges]
      )
    end
  end

end
