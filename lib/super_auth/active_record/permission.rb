class SuperAuth::ActiveRecord::Permission < ActiveRecord::Base
  self.table_name = 'super_auth_permissions'

  has_many :edges, class_name: 'SuperAuth::ActiveRecord::Edge'
  scope :with_edges, -> { joins(:edges) }
  scope :with_roles, -> { from(%Q[(#{SuperAuth::Permission.with_roles.sql}) as super_auth_permissions]) }
end
