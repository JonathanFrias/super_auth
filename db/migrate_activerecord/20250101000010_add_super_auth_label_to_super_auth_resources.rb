class AddSuperAuthLabelToSuperAuthResources < ActiveRecord::Migration[7.0]
  def change
    add_column :super_auth_resources, :super_auth_label, :string
  end
end
