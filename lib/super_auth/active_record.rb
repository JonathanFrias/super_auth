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
