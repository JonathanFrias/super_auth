require "active_record"
module SuperAuth::ActiveRecord
end

class ActiveRecord::Base
  class << self
    # Filter this model through the ByCurrentUser scope, keyed on the class's
    # own name. parent: names the columns through which a grant on another
    # record reaches a row — the row's tenancy, read off the row itself —
    # each with the types whose rows admit through it: a Hash
    # {column:, resource_type: String|[String]} or an Array of them, the
    # shape SuperAuth::Reach normalises and SuperAuth::RLS.enable takes under
    # the same keyword, so the two layers cannot describe different reaches.
    # wildcard: false drops the type-level step (a row with
    # resource_external_id NULL admitting every record of the type), which
    # is otherwise always emitted. The reach is validated here and the table
    # is not read: the columns are checked on the first query, so a process
    # can boot before its migrations run. On a subclass the call replaces
    # the parents for that subclass alone and adds no second scope.
    def super_auth(parent: nil, wildcard: true)
      reach = SuperAuth::Reach.normalize(resource_type: name, parent: parent)
      include SuperAuth::ActiveRecord::ByCurrentUser unless include?(SuperAuth::ActiveRecord::ByCurrentUser)
      self.super_auth_reach = reach
      self.super_auth_wildcard = wildcard
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
