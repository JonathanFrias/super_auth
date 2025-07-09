require 'spec_helper'

RSpec.describe SuperAuth do
  let(:db) { SuperAuth.db }

  before do
    db[:super_auth_edges].delete
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  it "can create a group tree" do
    root_group = SuperAuth::Group.create(name: 'root')
      admin_group = SuperAuth::Group.create(name: 'admin', parent: root_group)
        user_group = SuperAuth::Group.create(name: 'user', parent: admin_group)

    descendants = root_group.descendants_dataset.order(:id)
    expect(descendants).to match_array([root_group, admin_group, user_group])

    expect(descendants.map { |d| d[:group_path] }).to eq ["#{root_group.id}", "#{root_group.id},#{admin_group.id}", "#{root_group.id},#{admin_group.id},#{user_group.id}"]
  end

  it "can create a role tree" do
    root_role = SuperAuth::Role.create(name: 'root')
      admin_role = SuperAuth::Role.create(name: 'admin', parent: root_role)
        user_role = SuperAuth::Role.create(name: 'user', parent: admin_role)

    descendants = root_role.descendants_dataset.order(:id)
    expect(descendants).to match_array([root_role, admin_role, user_role])

    expect(descendants.map { |d| d[:role_path] }).to eq ["#{root_role.id}", "#{root_role.id},#{admin_role.id}", "#{root_role.id},#{admin_role.id},#{user_role.id}"]
  end

  let(:users_and_groups) do
    @ceo = SuperAuth::User.create(name: 'CEO')
    @senior_developer = SuperAuth::User.create(name: 'Señor Dev')
    @noob_developer = SuperAuth::User.create(name: 'gotta get good')
    @marketing_bro = SuperAuth::User.create(name: "Buy this pen!")

    @organization = SuperAuth::Group.create(name: 'Foobar Corp')
      @marketing = SuperAuth::Group.create(name: 'marketing', parent: @organization)

      @developers = SuperAuth::Group.create(name: 'developers', parent: @organization)
        @feature1 = SuperAuth::Group.create(name: 'feature1', parent: @developers)
        _feature = SuperAuth::Group.create(name: 'feature2', parent: @developers)

    SuperAuth::Edge.create(user: @ceo, group: @organization)
    SuperAuth::Edge.create(user: @senior_developer, group: @developers)
    SuperAuth::Edge.create(user: @marketing_bro, group: @marketing)
    SuperAuth::Edge.create(user: @noob_developer, group: @feature1)
  end

  it "can merge users with groups" do
    expect(db[:super_auth_users].count).to eq 0
    expect(SuperAuth::User.count).to eq 0
    users_and_groups
    ceo_res, senior_developer_res, noob_developer_res, marketing_bro_res = SuperAuth::User.with_groups.all.sort_by(&:id)
    [
      # result               user_id,               group_id,         group_name     parent_id,        group_path,                                              group_name_path
      [ceo_res,              @ceo.id,               @organization.id, 'Foobar Corp', nil,              "#{@organization.id}",                                   "Foobar Corp"],
      [senior_developer_res, @senior_developer.id,  @developers.id,   'developers',  @organization.id, "#{@organization.id},#{@developers.id}",                 "Foobar Corp,developers"],
      [noob_developer_res,   @noob_developer.id,    @feature1.id,     'feature1',    @developers.id,   "#{@organization.id},#{@developers.id},#{@feature1.id}", "Foobar Corp,developers,feature1"],
      [marketing_bro_res,    @marketing_bro.id,     @marketing.id,    'marketing',   @organization.id, "#{@organization.id},#{@marketing.id}",                  "Foobar Corp,marketing"],
    ].each do |res, user_id, group_id, group_name, parent_id, group_path, group_name_path|
      expect(res.id.to_s).to eq user_id.to_s
      expect(res[:group_id].to_s).to eq group_id.to_s
      expect(res[:group_name]).to eq group_name
      expect(res[:parent_id].to_s).to eq parent_id.to_s
      expect(res[:group_path]).to eq group_path
      expect(res[:group_name_path]).to eq group_name_path
    end
  end

  let(:permissions_and_roles) do
    @read_access = SuperAuth::Permission.create(name: 'read')
    @write_access = SuperAuth::Permission.create(name: 'write')
    @reboot_access = SuperAuth::Permission.create(name: 'reboot')
    @invoice = SuperAuth::Permission.create(name: 'invoice')

    @employee  = SuperAuth::Role.create(name: 'employee')
      @accounting = SuperAuth::Role.create(name: 'accounting', parent: @employee)

      @prod_access = SuperAuth::Role.create(name: 'production support', parent: @employee)
        @web = SuperAuth::Role.create(name: 'web', parent: @prod_access)
        @db1 = SuperAuth::Role.create(name: 'db1', parent: @prod_access)
        @db2 = SuperAuth::Role.create(name: 'db2', parent: @prod_access)

    SuperAuth::Edge.create(role: @prod_access, permission: @read_access)
    SuperAuth::Edge.create(role: @prod_access, permission: @write_access)
    SuperAuth::Edge.create(role: @prod_access, permission: @reboot_access)
    SuperAuth::Edge.create(role: @accounting, permission: @invoice)
  end

  it "can merge permissions with roles" do
    permissions_and_roles
    read_res, write_res, reboot_res, invoice_res = SuperAuth::Permission.with_roles.all.sort_by(&:id)
    [
      # result      permission_id,     role_id,        role_name              parent_id,       role_path,                            role_name_path
      [read_res,    @read_access.id,   @prod_access.id, 'production support', @employee.id,    "#{@employee.id},#{@prod_access.id}", "employee,production support"],
      [write_res,   @write_access.id,  @prod_access.id, 'production support', @employee.id,    "#{@employee.id},#{@prod_access.id}", "employee,production support"],
      [reboot_res,  @reboot_access.id, @prod_access.id, 'production support', @employee.id,    "#{@employee.id},#{@prod_access.id}", "employee,production support"],
      [invoice_res, @invoice.id,       @accounting.id,  'accounting',         @employee.id,    "#{@employee.id},#{@accounting.id}",  "employee,accounting"],
    ].each do |res, permission_id, role_id, role_name, parent_id, role_path, role_name_path|
      expect(res.id.to_s).to eq permission_id.to_s
      expect(res[:role_id].to_s).to eq role_id.to_s
      expect(res[:role_name]).to eq role_name
      expect(res[:parent_id].to_s).to eq parent_id.to_s
      expect(res[:role_path]).to eq role_path
      expect(res[:role_name_path]).to eq role_name_path
    end
  end

  it "users<->groups<->roles<->permissions<->resources" do
    permissions_and_roles
    users_and_groups

    resource = SuperAuth::Resource.create(name: 'resource')

    SuperAuth::Edge.create(role: @employee, group: @organization)
    SuperAuth::Edge.create(permission: @read_access, resource: resource)

    edges = SuperAuth::Edge.users_groups_roles_permissions_resources.sort_by { |v| v[:group_path] }
    expect(edges.map { |e| e[:user_name] }).to eq ['CEO', 'Buy this pen!', 'Señor Dev', 'gotta get good']
    expect(edges.map { |e| e[:group_name] }).to eq ['Foobar Corp', 'marketing', 'developers', 'feature1']
    expect(edges.map { |e| e[:role_name] }).to eq ['production support', 'production support', 'production support', 'production support']
    expect(edges.map { |e| e[:permission_name] }).to eq ['read', 'read', 'read', 'read']
    expect(edges.map { |e| e[:resource_name] }).to eq ['resource', 'resource', 'resource', 'resource']
  end

  it "users<->groups<->permissions<->resources" do
    permissions_and_roles
    users_and_groups

    resource = SuperAuth::Resource.create(name: 'resource')

    SuperAuth::Edge.create(permission: @reboot_access, group: @marketing)
    SuperAuth::Edge.create(resource: resource, permission: @reboot_access)

    edges = SuperAuth::Edge.users_groups_permissions_resources.sort_by { |v| v[:group_path] }

    expect(edges.count).to eq 1
  end

  it "users<->roles<->permissions<->resources" do
    permissions_and_roles
    users_and_groups

    resource = SuperAuth::Resource.create(name: 'resource')

    SuperAuth::Edge.create(user: @ceo, role: @prod_access)
    SuperAuth::Edge.create(role: @prod_access, permission: @reboot_access)
    SuperAuth::Edge.create(permission: @reboot_access, resource: resource)

    edges = SuperAuth::Edge.users_roles_permissions_resources.sort_by { |v| v[:group_path] }

    expect(edges.count).to eq 1
  end

  it "users<->permissions<->resources" do user = SuperAuth::User.create(name: "user")
    permission = SuperAuth::Permission.create(name: "read")
    resource = SuperAuth::Resource.create(name: "resource")

    SuperAuth::Edge.create(user: user, permission: permission)
    SuperAuth::Edge.create(permission: permission, resource: resource)

    expect(SuperAuth::Edge.users_permissions_resources.count).to eq 1
  end

  it "users<->resources" do
    user = SuperAuth::User.create(name: "user")
    resource = SuperAuth::Resource.create(name: "resource")
    SuperAuth::Edge.create(user: user, resource: resource)
    expect(SuperAuth::Edge.users_resources.count).to eq 1
  end
end
