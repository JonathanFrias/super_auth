class SuperAuth::Group < Sequel::Model(:super_auth_groups)
  include SuperAuth::Nestable
end
