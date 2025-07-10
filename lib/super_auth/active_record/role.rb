class SuperAuth::ActiveRecord::Role < ActiveRecord::Base
  self.table_name = 'super_auth_roles'

  belongs_to :parent, class_name: 'SuperAuth::ActiveRecord::Role'

  def descendants_dataset
    sql = SuperAuth::Role.new(id: self.id, parent_id: self.parent_id).descendants_dataset.sql
    self.class.from(%Q[(#{sql}) as super_auth_roles])
  end
end
