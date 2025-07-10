class SuperAuth::Group < Sequel::Model(:super_auth_groups)
  unrestrict_primary_key # For ActiveRecord
  include SuperAuth::Nestable
end
