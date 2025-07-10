class SuperAuth::Role < Sequel::Model(:super_auth_roles)
  unrestrict_primary_key # For ActiveRecord
  include SuperAuth::Nestable
end
