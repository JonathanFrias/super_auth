class SuperAuth::ActiveRecord::User < ActiveRecord::Base
  self.table_name = 'super_auth_users'

  def model_name = ActiveModel::Name.new(:user)

  def system? = SuperAuth::ActiveRecord::User == self
  def self.system = find_or_create_by(name: "system")
end
