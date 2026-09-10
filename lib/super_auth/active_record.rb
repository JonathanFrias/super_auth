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
    # the same keyword, so the same arguments produce the same map in both
    # layers; whether the arguments agree is what RLS.current? checks.
    # wildcard: false drops the type-level step (a row with
    # resource_external_id NULL admitting every record of the type), which
    # is otherwise always emitted. Omitting it keeps whatever the class
    # already has — the default on a first declaration, the base's value on a
    # subclass — because a subclass usually re-declares to replace its
    # parents, and taking the keyword's default there would silently hand
    # back the type-level step a base opted out of, against a policy built
    # without it. Say wildcard: true to put it back. Only true and false are
    # accepted, with the message RLS.enable gives: nil there means "drop the
    # step" to the scope and "leave it alone" here, and a truthy string keeps
    # it, so neither may pass silently. The reach is validated here and the
    # table is not read: the columns are checked on the first query, so a
    # process can boot before its migrations run. On a subclass the call
    # replaces the parents for that subclass alone and adds no second scope.
    def super_auth(parent: nil, wildcard: nil)
      unless [true, false, nil].include?(wildcard)
        raise SuperAuth::Error, "wildcard: must be true or false, got #{wildcard.inspect}"
      end
      reach = SuperAuth::Reach.normalize(resource_type: name, parent: parent)
      include SuperAuth::ActiveRecord::ByCurrentUser unless include?(SuperAuth::ActiveRecord::ByCurrentUser)
      self.super_auth_reach = reach
      self.super_auth_wildcard = wildcard unless wildcard.nil?
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
