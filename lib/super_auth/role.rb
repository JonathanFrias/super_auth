class SuperAuth::Role < Sequel::Model(:super_auth_roles)
  include SuperAuth::Nestable
end