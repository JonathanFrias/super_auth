class SuperAuth::ActiveRecord::Group < ActiveRecord::Base
  self.table_name = 'super_auth_groups'

  belongs_to :parent, class_name: 'SuperAuth::ActiveRecord::Group'

  def descendants_dataset
    sql = SuperAuth::Group.new(id: self.id, parent_id: self.parent_id).descendants_dataset.sql
    self.class.from(%Q[(#{sql}) as super_auth_groups])
  end
end
