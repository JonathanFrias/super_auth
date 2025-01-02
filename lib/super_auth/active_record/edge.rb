class SuperAuth::ActiveRecord::Edge < ActiveRecord::Base
  self.table_name = 'super_auth_edges'
end
SuperAuth::Edge = SuperAuth::ActiveRecord::Edge
