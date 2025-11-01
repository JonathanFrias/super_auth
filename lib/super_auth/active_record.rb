require "active_record"
module SuperAuth::ActiveRecord
end

class ActiveRecord::Base
  class << self
    def super_auth
      include SuperAuth::ActiveRecord::ByCurrentUser
    end
  end
end

require "super_auth/active_record/authorization"
require "super_auth/active_record/by_current_user"
require "super_auth/active_record/edge"
require "super_auth/active_record/group"
require "super_auth/active_record/permission"
require "super_auth/active_record/resource"
require "super_auth/active_record/role"
require "super_auth/active_record/user"
