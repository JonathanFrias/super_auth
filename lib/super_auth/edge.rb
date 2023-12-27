class SuperAuth::Edge < Sequel::Model(:edges)
  many_to_one :user
  many_to_one :group
  many_to_one :permission
  many_to_one :role
  many_to_one :resource
end