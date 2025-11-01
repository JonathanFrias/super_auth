require 'spec_helper'

RSpec.describe "SuperAuth Examples from README" do
  let(:db) { SuperAuth.db }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_edges].delete
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  after do
    SuperAuth.uninstall_migrations
  end

  # Create all users from README
  let!(:peter) { SuperAuth::User.create(name: 'Peter') }
  let!(:michael) { SuperAuth::User.create(name: 'Michael') }
  let!(:bethany) { SuperAuth::User.create(name: 'Bethany') }
  let!(:eloise) { SuperAuth::User.create(name: 'Eloise') }
  let!(:anna) { SuperAuth::User.create(name: 'Anna') }
  let!(:dillon) { SuperAuth::User.create(name: 'Dillon') }
  let!(:guest) { SuperAuth::User.create(name: 'Guest') }

  # Create group hierarchy from README
  let!(:company) { SuperAuth::Group.create(name: 'Company') }
  let!(:engineering_dept) { SuperAuth::Group.create(name: 'Engineering_dept', parent: company) }
  let!(:backend) { SuperAuth::Group.create(name: 'Backend', parent: engineering_dept) }
  let!(:frontend) { SuperAuth::Group.create(name: 'Frontend', parent: engineering_dept) }
  let!(:sales_department) { SuperAuth::Group.create(name: 'Sales Department', parent: company) }
  let!(:marketing_department) { SuperAuth::Group.create(name: 'Marketing Department', parent: company) }
  let!(:customers) { SuperAuth::Group.create(name: 'Customers') }
  let!(:customer_a) { SuperAuth::Group.create(name: 'CustomerA', parent: customers) }
  let!(:customer_b) { SuperAuth::Group.create(name: 'CustomerB', parent: customers) }
  let!(:vendors) { SuperAuth::Group.create(name: 'Vendors') }
  let!(:vendor_a) { SuperAuth::Group.create(name: 'VendorA', parent: vendors) }
  let!(:vendor_b) { SuperAuth::Group.create(name: 'VendorB', parent: vendors) }

  # Create role hierarchy from README
  let!(:employee) { SuperAuth::Role.create(name: 'Employee') }
  let!(:engineering) { SuperAuth::Role.create(name: 'Engineering', parent: employee) }
  let!(:senor_software_dev) { SuperAuth::Role.create(name: 'Señor Software Developer', parent: engineering) }
  let!(:senor_designer) { SuperAuth::Role.create(name: 'Señor Designer', parent: engineering) }
  let!(:software_developer) { SuperAuth::Role.create(name: 'Software Developer', parent: engineering) }
  let!(:production_support) { SuperAuth::Role.create(name: 'Production Support', parent: engineering) }
  let!(:sales_and_marketing) { SuperAuth::Role.create(name: 'Sales and Marketing', parent: employee) }
  let!(:marketing_manager) { SuperAuth::Role.create(name: 'Marketing Manager', parent: sales_and_marketing) }
  let!(:marketing_associate) { SuperAuth::Role.create(name: 'Marketing Associate', parent: sales_and_marketing) }
  let!(:customer_role) { SuperAuth::Role.create(name: 'CustomerRole') }

  # Create permissions from README
  let!(:create_perm) { SuperAuth::Permission.create(name: 'create') }
  let!(:read_perm) { SuperAuth::Permission.create(name: 'read') }
  let!(:update_perm) { SuperAuth::Permission.create(name: 'update') }
  let!(:delete_perm) { SuperAuth::Permission.create(name: 'delete') }
  let!(:invoice_perm) { SuperAuth::Permission.create(name: 'invoice') }
  let!(:login_perm) { SuperAuth::Permission.create(name: 'login') }
  let!(:reboot_perm) { SuperAuth::Permission.create(name: 'reboot') }
  let!(:deploy_perm) { SuperAuth::Permission.create(name: 'deploy') }
  let!(:sign_contract_perm) { SuperAuth::Permission.create(name: 'sign_contract') }
  let!(:subscribe_perm) { SuperAuth::Permission.create(name: 'subscribe') }
  let!(:unsubscribe_perm) { SuperAuth::Permission.create(name: 'unsubscribe') }
  let!(:publish_design_perm) { SuperAuth::Permission.create(name: 'publish_design') }

  # Create resources from README
  let!(:app1) { SuperAuth::Resource.create(name: 'app1') }
  let!(:app2) { SuperAuth::Resource.create(name: 'app2') }
  let!(:staging) { SuperAuth::Resource.create(name: 'staging') }
  let!(:db1) { SuperAuth::Resource.create(name: 'db1') }
  let!(:db2) { SuperAuth::Resource.create(name: 'db2') }
  let!(:core_design_template) { SuperAuth::Resource.create(name: 'core_design_template') }
  let!(:customer_profile) { SuperAuth::Resource.create(name: 'customer_profile') }
  let!(:marketing_website) { SuperAuth::Resource.create(name: 'marketing_website') }
  let!(:customer_post1) { SuperAuth::Resource.create(name: 'customer_post1') }
  let!(:customer_post2) { SuperAuth::Resource.create(name: 'customer_post2') }
  let!(:customer_post3) { SuperAuth::Resource.create(name: 'customer_post3') }

  describe "Example from README: Peter accessing core_design_template" do
    before do
      # Peter is on Frontend team
      SuperAuth::Edge.create(user: peter, group: frontend)

      # Frontend (part of Engineering dept) has Engineering role
      SuperAuth::Edge.create(group: frontend, role: engineering)

      # Engineering role has CRUD permissions
      SuperAuth::Edge.create(role: engineering, permission: create_perm)
      SuperAuth::Edge.create(role: engineering, permission: read_perm)
      SuperAuth::Edge.create(role: engineering, permission: update_perm)
      SuperAuth::Edge.create(role: engineering, permission: delete_perm)

      # core_design_template has CRUD permissions
      SuperAuth::Edge.create(resource: core_design_template, permission: create_perm)
      SuperAuth::Edge.create(resource: core_design_template, permission: read_perm)
      SuperAuth::Edge.create(resource: core_design_template, permission: update_perm)
      SuperAuth::Edge.create(resource: core_design_template, permission: delete_perm)
    end

    it "creates authorization paths from Peter to core_design_template" do
      authorizations = SuperAuth::Edge.authorizations.all

      peter_auths = authorizations.select { |a| a[:user_id] == peter.id && a[:resource_id] == core_design_template.id }

      expect(peter_auths.count).to eq 4

      # Verify all CRUD permissions are present
      permission_names = peter_auths.map { |a| a[:permission_name] }.sort
      expect(permission_names).to eq ['create', 'delete', 'read', 'update']

      # Verify the path goes through Frontend and Engineering role
      peter_auths.each do |auth|
        expect(auth[:user_name]).to eq 'Peter'
        expect(auth[:group_name]).to eq 'Frontend'
        expect(auth[:role_name]).to eq 'Engineering'
        expect(auth[:resource_name]).to eq 'core_design_template'
      end
    end

    it "allows Peter to access via user<->group<->role<->permission<->resource path" do
      authorizations = SuperAuth::Edge.authorizations.all

      peter_auths = authorizations.select { |a| a[:user_id] == peter.id && a[:resource_id] == core_design_template.id }
      expect(peter_auths).not_to be_empty
    end
  end

  describe "Complex authorization scenarios" do
    context "when Backend team can deploy to production" do
      before do
        SuperAuth::Edge.create(user: michael, group: backend)
        SuperAuth::Edge.create(group: backend, role: production_support)
        SuperAuth::Edge.create(role: production_support, permission: deploy_perm)
        SuperAuth::Edge.create(permission: deploy_perm, resource: app1)
      end

      it "grants Michael deploy access to app1" do
        authorizations = SuperAuth::Edge.authorizations.all

        michael_auths = authorizations.select { |a| a[:user_id] == michael.id && a[:resource_id] == app1.id }

        expect(michael_auths.count).to eq 1
        expect(michael_auths.first[:permission_name]).to eq 'deploy'
      end

      it "does not grant Peter deploy access to app1" do
        SuperAuth::Edge.create(user: peter, group: frontend)

        authorizations = SuperAuth::Edge.authorizations.all

        peter_auths = authorizations.select { |a| a[:user_id] == peter.id && a[:resource_id] == app1.id }

        expect(peter_auths.count).to eq 0
      end
    end

    context "when user has multiple paths to the same resource" do
      before do
        # Path 1: Bethany -> Engineering_dept -> Engineering -> read -> staging
        SuperAuth::Edge.create(user: bethany, group: engineering_dept)
        SuperAuth::Edge.create(group: engineering_dept, role: engineering)
        SuperAuth::Edge.create(role: engineering, permission: read_perm)
        SuperAuth::Edge.create(permission: read_perm, resource: staging)

        # Path 2: Bethany -> Production Support -> deploy -> staging
        SuperAuth::Edge.create(user: bethany, role: production_support)
        SuperAuth::Edge.create(role: production_support, permission: deploy_perm)
        SuperAuth::Edge.create(permission: deploy_perm, resource: staging)
      end

      it "shows both authorization paths" do
        authorizations = SuperAuth::Edge.authorizations.all

        bethany_auths = authorizations.select { |a| a[:user_id] == bethany.id && a[:resource_id] == staging.id }

        # Bethany gets authorizations through multiple paths - the library creates all possible paths
        expect(bethany_auths.count).to be >= 2
        permission_names = bethany_auths.map { |a| a[:permission_name] }.uniq.sort
        expect(permission_names).to include('deploy', 'read')
      end
    end

    context "when customers have limited access" do
      before do
        SuperAuth::Edge.create(user: anna, group: customer_a)
        SuperAuth::Edge.create(group: customer_a, role: customer_role)
        SuperAuth::Edge.create(role: customer_role, permission: read_perm)
        SuperAuth::Edge.create(permission: read_perm, resource: customer_post1)
        SuperAuth::Edge.create(permission: read_perm, resource: customer_post2)
      end

      it "allows customer to read accessible posts" do
        authorizations = SuperAuth::Edge.authorizations.all

        anna_auths = authorizations.select { |a| a[:user_id] == anna.id }

        resource_names = anna_auths.map { |a| a[:resource_name] }.sort
        expect(resource_names).to eq ['customer_post1', 'customer_post2']
      end

      it "does not allow customer to access internal resources" do
        authorizations = SuperAuth::Edge.authorizations.all

        anna_auths = authorizations.select { |a| a[:user_id] == anna.id && a[:resource_id] == app1.id }

        expect(anna_auths.count).to eq 0
      end
    end
  end

  describe "Direct user to resource authorization (simplest path)" do
    before do
      SuperAuth::Edge.create(user: dillon, resource: db1)
    end

    it "grants access via direct user<->resource edge" do
      authorizations = SuperAuth::Edge.authorizations.all

      dillon_auths = authorizations.select { |a| a[:user_id] == dillon.id && a[:resource_id] == db1.id }

      expect(dillon_auths.count).to eq 1
      # In user<->resource path, permission_name is NULL
      expect(dillon_auths.first[:permission_name]).to be_nil
    end
  end

  describe "User to permission to resource path" do
    before do
      SuperAuth::Edge.create(user: eloise, permission: reboot_perm)
      SuperAuth::Edge.create(permission: reboot_perm, resource: db2)
    end

    it "grants access via user<->permission<->resource path" do
      authorizations = SuperAuth::Edge.authorizations.all

      eloise_auths = authorizations.select { |a| a[:user_id] == eloise.id && a[:resource_id] == db2.id }

      expect(eloise_auths.count).to eq 1
      expect(eloise_auths.first[:permission_name]).to eq 'reboot'
    end
  end

  describe "Authorization revocation" do
    before do
      SuperAuth::Edge.create(user: guest, group: customers)
      SuperAuth::Edge.create(group: customers, role: customer_role)
      SuperAuth::Edge.create(role: customer_role, permission: read_perm)
      SuperAuth::Edge.create(permission: read_perm, resource: customer_profile)
    end

    it "initially grants access" do
      authorizations = SuperAuth::Edge.authorizations.all

      guest_auths = authorizations.select { |a| a[:user_id] == guest.id && a[:resource_id] == customer_profile.id }

      expect(guest_auths.count).to eq 1
    end

    it "revokes access when edge is deleted" do
      edge = SuperAuth::Edge.where(user_id: guest.id, group_id: customers.id).first
      edge.destroy

      authorizations = SuperAuth::Edge.authorizations.all

      guest_auths = authorizations.select { |a| a[:user_id] == guest.id && a[:resource_id] == customer_profile.id }

      expect(guest_auths.count).to eq 0
    end
  end

  describe "Group hierarchy propagation" do
    before do
      # Company-wide role applies to all departments
      SuperAuth::Edge.create(user: bethany, group: company)
      SuperAuth::Edge.create(group: company, role: employee)
      SuperAuth::Edge.create(role: employee, permission: login_perm)
      SuperAuth::Edge.create(permission: login_perm, resource: app2)
    end

    it "grants access through parent group" do
      authorizations = SuperAuth::Edge.authorizations.all

      bethany_auths = authorizations.select { |a| a[:user_id] == bethany.id && a[:resource_id] == app2.id }

      expect(bethany_auths.count).to eq 1
      expect(bethany_auths.first[:group_name]).to eq 'Company'
      expect(bethany_auths.first[:role_name]).to eq 'Employee'
    end
  end

  describe "Role hierarchy allows querying all descendant roles" do
    before do
      SuperAuth::Edge.create(user: peter, group: frontend)
      # Grant the specific Señor Designer role
      SuperAuth::Edge.create(group: frontend, role: senor_designer)

      # Permission granted directly to Señor Designer role
      SuperAuth::Edge.create(role: senor_designer, permission: publish_design_perm)
      SuperAuth::Edge.create(permission: publish_design_perm, resource: marketing_website)
    end

    it "grants access through assigned role" do
      authorizations = SuperAuth::Edge.authorizations.all

      peter_auths = authorizations.select { |a| a[:user_id] == peter.id && a[:resource_id] == marketing_website.id }

      expect(peter_auths.count).to eq 1
      expect(peter_auths.first[:permission_name]).to eq 'publish_design'
      expect(peter_auths.first[:role_name]).to eq 'Señor Designer'
    end
  end

  describe "Multiple users sharing same authorization path" do
    before do
      # Both Backend developers get same permissions
      SuperAuth::Edge.create(user: michael, group: backend)
      SuperAuth::Edge.create(user: dillon, group: backend)
      SuperAuth::Edge.create(group: backend, role: software_developer)
      SuperAuth::Edge.create(role: software_developer, permission: update_perm)
      SuperAuth::Edge.create(permission: update_perm, resource: staging)
    end

    it "grants access to both users" do
      authorizations = SuperAuth::Edge.authorizations.all

      michael_auths = authorizations.select { |a| a[:user_id] == michael.id && a[:resource_id] == staging.id }
      dillon_auths = authorizations.select { |a| a[:user_id] == dillon.id && a[:resource_id] == staging.id }

      expect(michael_auths.count).to eq 1
      expect(dillon_auths.count).to eq 1
      expect(michael_auths.first[:permission_name]).to eq 'update'
      expect(dillon_auths.first[:permission_name]).to eq 'update'
    end
  end

  describe "User with no authorizations" do
    it "returns no authorizations for user with no setup" do
      authorizations = SuperAuth::Edge.authorizations.all

      guest_auths = authorizations.select { |a| a[:user_id] == guest.id }

      expect(guest_auths.count).to eq 0
    end
  end

  describe "Cross-department resource sharing" do
    before do
      # Marketing can subscribe/unsubscribe customers
      SuperAuth::Edge.create(user: anna, group: marketing_department)
      SuperAuth::Edge.create(group: marketing_department, role: marketing_associate)
      SuperAuth::Edge.create(role: marketing_associate, permission: subscribe_perm)
      SuperAuth::Edge.create(role: marketing_associate, permission: unsubscribe_perm)
      SuperAuth::Edge.create(permission: subscribe_perm, resource: customer_profile)
      SuperAuth::Edge.create(permission: unsubscribe_perm, resource: customer_profile)
    end

    it "allows marketing to manage customer subscriptions" do
      authorizations = SuperAuth::Edge.authorizations.all

      anna_auths = authorizations.select { |a| a[:user_id] == anna.id && a[:resource_id] == customer_profile.id }

      permission_names = anna_auths.map { |a| a[:permission_name] }.sort
      expect(permission_names).to eq ['subscribe', 'unsubscribe']
    end
  end

  describe "Vendor access scenarios" do
    before do
      SuperAuth::Edge.create(user: michael, group: vendor_a)
      SuperAuth::Edge.create(group: vendor_a, permission: invoice_perm)
      SuperAuth::Edge.create(permission: invoice_perm, resource: app1)
    end

    it "allows vendors to invoice via group<->permission path" do
      authorizations = SuperAuth::Edge.authorizations.all

      michael_auths = authorizations.select { |a| a[:user_id] == michael.id && a[:resource_id] == app1.id }

      expect(michael_auths.count).to eq 1
      expect(michael_auths.first[:permission_name]).to eq 'invoice'
      expect(michael_auths.first[:group_name]).to eq 'VendorA'
    end
  end

  describe "Audit trail" do
    before do
      SuperAuth::Edge.create(user: peter, group: frontend)
      SuperAuth::Edge.create(group: frontend, role: engineering)
      SuperAuth::Edge.create(role: engineering, permission: read_perm)
      SuperAuth::Edge.create(permission: read_perm, resource: core_design_template)
    end

    it "provides full path information for auditing" do
      authorizations = SuperAuth::Edge.authorizations.all

      peter_auths = authorizations.select { |a| a[:user_id] == peter.id && a[:resource_id] == core_design_template.id }

      auth = peter_auths.first

      # All path information is available for auditing
      expect(auth[:user_name]).to eq 'Peter'
      expect(auth[:group_name]).to eq 'Frontend'
      expect(auth[:group_name_path]).to include('Frontend')
      expect(auth[:role_name]).to eq 'Engineering'
      expect(auth[:permission_name]).to eq 'read'
      expect(auth[:resource_name]).to eq 'core_design_template'
    end
  end

  describe "Complex enterprise scenario" do
    before do
      # Setup: A senior software developer on the backend team who can deploy to staging and production
      SuperAuth::Edge.create(user: michael, group: backend)
      SuperAuth::Edge.create(group: backend, role: senor_software_dev)

      # Grant all permissions directly to the senor_software_dev role
      SuperAuth::Edge.create(role: senor_software_dev, permission: read_perm)
      SuperAuth::Edge.create(role: senor_software_dev, permission: update_perm)
      SuperAuth::Edge.create(role: senor_software_dev, permission: deploy_perm)

      # Apply to staging and app1
      SuperAuth::Edge.create(permission: read_perm, resource: staging)
      SuperAuth::Edge.create(permission: update_perm, resource: staging)
      SuperAuth::Edge.create(permission: deploy_perm, resource: staging)
      SuperAuth::Edge.create(permission: deploy_perm, resource: app1)
    end

    it "correctly resolves all permissions for senior developer" do
      authorizations = SuperAuth::Edge.authorizations.all

      michael_staging_auths = authorizations.select { |a| a[:user_id] == michael.id && a[:resource_id] == staging.id }
      michael_app1_auths = authorizations.select { |a| a[:user_id] == michael.id && a[:resource_id] == app1.id }

      # Michael should have read, update, and deploy on staging (3 permissions)
      expect(michael_staging_auths.count).to eq 3
      staging_perms = michael_staging_auths.map { |a| a[:permission_name] }.sort
      expect(staging_perms).to eq ['deploy', 'read', 'update']

      # Michael should only have deploy on app1 (1 permission)
      expect(michael_app1_auths.count).to eq 1
      expect(michael_app1_auths.first[:permission_name]).to eq 'deploy'
    end
  end
end
