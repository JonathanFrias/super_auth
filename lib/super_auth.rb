# frozen_string_literal: true

require_relative "super_auth/version"
require 'sequel'

module SuperAuth
  class Error < StandardError; end
  autoload :Group, 'super_auth/group'
  autoload :Permission, 'super_auth/group'
  autoload :Resource, 'super_auth/resource'
  autoload :Role, 'super_auth/role'
  autoload :User, 'super_auth/user'
end
