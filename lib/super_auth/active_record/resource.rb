class SuperAuth::ActiveRecord::Resource < ActiveRecord::Base
  self.table_name = 'super_auth_resources'
  belongs_to :external, polymorphic: true
end
