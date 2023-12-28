class SuperAuth::Group < Sequel::Model(:groups)
  include SuperAuth::Nestable
end
