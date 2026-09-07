class SuperAuth::ActiveRecord::User < ActiveRecord::Base
  self.table_name = 'super_auth_users'

  belongs_to :external, polymorphic: true, optional: true

  def model_name = ActiveModel::Name.new(:user)

  # A read: runtime roles only get SELECT on this table. `.system` creates
  # the row when missing and belongs to migrations, seeds and consoles.
  def system? = self.class.find_by(name: "system") == self
  def self.system = find_or_create_by(name: "system")

  has_many :edges, class_name: 'SuperAuth::ActiveRecord::Edge'
  scope :with_edges, -> { joins(:edges) }
  scope :with_groups, -> { from(%Q[(#{SuperAuth::User.with_groups.sql}) as super_auth_users]) }
end
