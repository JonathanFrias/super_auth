class SuperAuth::Role < Sequel::Model(:roles)
  include SuperAuth::Nestable
end