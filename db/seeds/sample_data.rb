# Sample data based on the README examples
# This seed file creates a complete authorization graph for demonstration

puts "Creating sample data for SuperAuth..."

# Initialize SuperAuth
require 'super_auth'
SuperAuth.load

# Detect which ORM we're using
if defined?(SuperAuth::ActiveRecord::User)
  User = SuperAuth::ActiveRecord::User
  Group = SuperAuth::ActiveRecord::Group
  Role = SuperAuth::ActiveRecord::Role
  Permission = SuperAuth::ActiveRecord::Permission
  Resource = SuperAuth::ActiveRecord::Resource
  Edge = SuperAuth::ActiveRecord::Edge
else
  User = SuperAuth::User
  Group = SuperAuth::Group
  Role = SuperAuth::Role
  Permission = SuperAuth::Permission
  Resource = SuperAuth::Resource
  Edge = SuperAuth::Edge
end

# Clear existing data (optional - comment out if you don't want this)
puts "Clearing existing data..."
Edge.delete_all
User.delete_all
Group.delete_all
Role.delete_all
Permission.delete_all
Resource.delete_all

# Create users
puts "Creating users..."
peter = User.create!(name: 'Peter')
michael = User.create!(name: 'Michael')
bethany = User.create!(name: 'Bethany')
eloise = User.create!(name: 'Eloise')
anna = User.create!(name: 'Anna')
dillon = User.create!(name: 'Dillon')
guest = User.create!(name: 'Guest')

# Create group hierarchy
puts "Creating groups..."
company = Group.create!(name: 'Company')
engineering_dept = Group.create!(name: 'Engineering_dept', parent: company)
backend = Group.create!(name: 'Backend', parent: engineering_dept)
frontend = Group.create!(name: 'Frontend', parent: engineering_dept)
sales_department = Group.create!(name: 'Sales Department', parent: company)
marketing_department = Group.create!(name: 'Marketing Department', parent: company)
customers = Group.create!(name: 'Customers')
customer_a = Group.create!(name: 'CustomerA', parent: customers)
customer_b = Group.create!(name: 'CustomerB', parent: customers)
vendors = Group.create!(name: 'Vendors')
vendor_a = Group.create!(name: 'VendorA', parent: vendors)
vendor_b = Group.create!(name: 'VendorB', parent: vendors)

# Create role hierarchy
puts "Creating roles..."
employee = Role.create!(name: 'Employee')
engineering = Role.create!(name: 'Engineering', parent: employee)
senor_software_dev = Role.create!(name: 'Señor Software Developer', parent: engineering)
senor_designer = Role.create!(name: 'Señor Designer', parent: engineering)
software_developer = Role.create!(name: 'Software Developer', parent: engineering)
production_support = Role.create!(name: 'Production Support', parent: engineering)
sales_and_marketing = Role.create!(name: 'Sales and Marketing', parent: employee)
marketing_manager = Role.create!(name: 'Marketing Manager', parent: sales_and_marketing)
marketing_associate = Role.create!(name: 'Marketing Associate', parent: sales_and_marketing)
customer_role = Role.create!(name: 'CustomerRole')

# Create permissions
puts "Creating permissions..."
create_perm = Permission.create!(name: 'create')
read_perm = Permission.create!(name: 'read')
update_perm = Permission.create!(name: 'update')
delete_perm = Permission.create!(name: 'delete')
invoice_perm = Permission.create!(name: 'invoice')
login_perm = Permission.create!(name: 'login')
reboot_perm = Permission.create!(name: 'reboot')
deploy_perm = Permission.create!(name: 'deploy')
sign_contract_perm = Permission.create!(name: 'sign_contract')
subscribe_perm = Permission.create!(name: 'subscribe')
unsubscribe_perm = Permission.create!(name: 'unsubscribe')
publish_design_perm = Permission.create!(name: 'publish_design')

# Create resources
puts "Creating resources..."
app1 = Resource.create!(name: 'app1')
app2 = Resource.create!(name: 'app2')
staging = Resource.create!(name: 'staging')
db1 = Resource.create!(name: 'db1')
db2 = Resource.create!(name: 'db2')
core_design_template = Resource.create!(name: 'core_design_template')
customer_profile = Resource.create!(name: 'customer_profile')
marketing_website = Resource.create!(name: 'marketing_website')
customer_post1 = Resource.create!(name: 'customer_post1')
customer_post2 = Resource.create!(name: 'customer_post2')
customer_post3 = Resource.create!(name: 'customer_post3')

# Create edges (authorization relationships)
puts "Creating authorization edges..."

# Example 1: Peter can access core_design_template through Frontend -> Engineering -> CRUD
Edge.create!(user: peter, group: frontend)
Edge.create!(group: frontend, role: engineering)
Edge.create!(role: engineering, permission: create_perm)
Edge.create!(role: engineering, permission: read_perm)
Edge.create!(role: engineering, permission: update_perm)
Edge.create!(role: engineering, permission: delete_perm)
Edge.create!(resource: core_design_template, permission: create_perm)
Edge.create!(resource: core_design_template, permission: read_perm)
Edge.create!(resource: core_design_template, permission: update_perm)
Edge.create!(resource: core_design_template, permission: delete_perm)

# Example 2: Michael can deploy to app1 through Backend -> Production Support
Edge.create!(user: michael, group: backend)
Edge.create!(group: backend, role: production_support)
Edge.create!(role: production_support, permission: deploy_perm)
Edge.create!(permission: deploy_perm, resource: app1)

# Example 3: Anna can read customer posts through CustomerA -> CustomerRole
Edge.create!(user: anna, group: customer_a)
Edge.create!(group: customer_a, role: customer_role)
Edge.create!(role: customer_role, permission: read_perm)
Edge.create!(permission: read_perm, resource: customer_post1)
Edge.create!(permission: read_perm, resource: customer_post2)

# Additional scenarios for demonstration

# Bethany has multiple authorization paths
Edge.create!(user: bethany, group: engineering_dept)
Edge.create!(group: engineering_dept, role: engineering)
Edge.create!(permission: read_perm, resource: staging)

# Bethany also has direct role assignment
Edge.create!(user: bethany, role: production_support)
Edge.create!(permission: deploy_perm, resource: staging)

# Dillon has direct resource access (simplest path)
Edge.create!(user: dillon, resource: db1)

# Eloise has user -> permission -> resource path
Edge.create!(user: eloise, permission: reboot_perm)
Edge.create!(permission: reboot_perm, resource: db2)

# Marketing department scenario
Edge.create!(user: anna, group: marketing_department)
Edge.create!(group: marketing_department, role: marketing_associate)
Edge.create!(role: marketing_associate, permission: subscribe_perm)
Edge.create!(role: marketing_associate, permission: unsubscribe_perm)
Edge.create!(permission: subscribe_perm, resource: customer_profile)
Edge.create!(permission: unsubscribe_perm, resource: customer_profile)

# Vendor access
Edge.create!(user: michael, group: vendor_a)
Edge.create!(group: vendor_a, permission: invoice_perm)
Edge.create!(permission: invoice_perm, resource: app1)

# Company-wide access
Edge.create!(user: bethany, group: company)
Edge.create!(group: company, role: employee)
Edge.create!(role: employee, permission: login_perm)
Edge.create!(permission: login_perm, resource: app2)

# Senior Designer role
Edge.create!(user: peter, group: frontend) # Already created above, but illustrating
Edge.create!(group: frontend, role: senor_designer)
Edge.create!(role: senor_designer, permission: publish_design_perm)
Edge.create!(permission: publish_design_perm, resource: marketing_website)

# Backend developers sharing permissions
Edge.create!(user: dillon, group: backend)
Edge.create!(group: backend, role: software_developer)
Edge.create!(role: software_developer, permission: update_perm)
Edge.create!(permission: update_perm, resource: staging)

# Senior software developer with multiple permissions
# (Michael already has vendor_a group)
Edge.create!(group: backend, role: senor_software_dev)
Edge.create!(role: senor_software_dev, permission: read_perm)
Edge.create!(role: senor_software_dev, permission: update_perm)
Edge.create!(role: senor_software_dev, permission: deploy_perm)
# Resources already connected above

puts "Sample data created successfully!"
puts "#{User.count} users, #{Group.count} groups, #{Role.count} roles"
puts "#{Permission.count} permissions, #{Resource.count} resources"
puts "#{Edge.count} authorization edges"
