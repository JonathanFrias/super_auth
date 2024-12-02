# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SuperAuth do
  Group = SuperAuth::Group
  User = SuperAuth::User
  Edge = SuperAuth::Edge
  Permission = SuperAuth::Permission
  Role = SuperAuth::Role
  Resource = SuperAuth::Resource

  let(:db) { Sequel::Model.db }

  before do
    db[:super_auth_edges].delete
    db[:super_auth_groups].delete
    db[:super_auth_users].delete
    db[:super_auth_permissions].delete
    db[:super_auth_roles].delete
    db[:super_auth_resources].delete
  end

  it "can create a group tree" do
    root_group = Group.create(name: 'root')
      admin_group = Group.create(name: 'admin', parent: root_group)
        user_group = Group.create(name: 'user', parent: admin_group)

    descendants = root_group.descendants_dataset.order(:id)
    expect(descendants).to match_array([root_group, admin_group, user_group])

    expect(descendants.map { |d| d[:group_path] }).to eq ["#{root_group.id}", "#{root_group.id},#{admin_group.id}", "#{root_group.id},#{admin_group.id},#{user_group.id}"]
  end

  it "can create a role tree" do
    root_role = Role.create(name: 'root')
      admin_role = Role.create(name: 'admin', parent: root_role)
        user_role = Role.create(name: 'user', parent: admin_role)

    descendants = root_role.descendants_dataset.order(:id)
    expect(descendants).to match_array([root_role, admin_role, user_role])

    expect(descendants.map { |d| d[:role_path] }).to eq ["#{root_role.id}", "#{root_role.id},#{admin_role.id}", "#{root_role.id},#{admin_role.id},#{user_role.id}"]
  end

  let(:users_and_groups) do
    @ceo = User.create(name: 'CEO')
    @senior_developer = User.create(name: 'Señor Dev')
    @noob_developer = User.create(name: 'gotta get good')
    @marketing_bro = User.create(name: "Buy this pen!")

    @organization = Group.create(name: 'Foobar Corp')
      @marketing = Group.create(name: 'marketing', parent: @organization)

      @developers = Group.create(name: 'developers', parent: @organization)
        @feature1 = Group.create(name: 'feature1', parent: @developers)
        _feature = Group.create(name: 'feature2', parent: @developers)

    Edge.create(user: @ceo, group: @organization)
    Edge.create(user: @senior_developer, group: @developers)
    Edge.create(user: @marketing_bro, group: @marketing)
    Edge.create(user: @noob_developer, group: @feature1)
  end

  it "can merge users with groups" do
    users_and_groups
    ceo_res, senior_developer_res, noob_developer_res, marketing_bro_res = User.with_groups.all.sort_by(&:id)
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
    @read_access = Permission.create(name: 'read')
    @write_access = Permission.create(name: 'write')
    @reboot_access = Permission.create(name: 'reboot')
    @invoice = Permission.create(name: 'invoice')

    @employee  = Role.create(name: 'employee')
      @accounting = Role.create(name: 'accounting', parent: @employee)

      @prod_access = Role.create(name: 'production support', parent: @employee)
        @web = Role.create(name: 'web', parent: @prod_access)
        @db1 = Role.create(name: 'db1', parent: @prod_access)
        @db2 = Role.create(name: 'db2', parent: @prod_access)

    Edge.create(role: @prod_access, permission: @read_access)
    Edge.create(role: @prod_access, permission: @write_access)
    Edge.create(role: @prod_access, permission: @reboot_access)
    Edge.create(role: @accounting, permission: @invoice)
  end

  it "can merge permissions with roles" do
    permissions_and_roles
    read_res, write_res, reboot_res, invoice_res = Permission.with_roles.all.sort_by(&:id)
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

    resource = Resource.create(name: 'resource')

    Edge.create(role: @employee, group: @organization)
    Edge.create(permission: @read_access, resource: resource)

    edges = Edge.users_groups_roles_permissions_resources.sort_by { |v| v[:group_path] }
    expect(edges.map { |e| e[:user_name] }).to eq ['CEO', 'Buy this pen!', 'Señor Dev', 'gotta get good']
    expect(edges.map { |e| e[:group_name] }).to eq ['Foobar Corp', 'marketing', 'developers', 'feature1']
    expect(edges.map { |e| e[:role_name] }).to eq ['production support', 'production support', 'production support', 'production support']
    expect(edges.map { |e| e[:permission_name] }).to eq ['read', 'read', 'read', 'read']
    expect(edges.map { |e| e[:resource_name] }).to eq ['resource', 'resource', 'resource', 'resource']
  end

  it "users<->groups<->permissions<->resources" do
    permissions_and_roles
    users_and_groups

    resource = Resource.create(name: 'resource')

    Edge.create(permission: @reboot_access, group: @marketing)
    Edge.create(resource: resource, permission: @reboot_access)

    edges = Edge.users_groups_permissions_resources.sort_by { |v| v[:group_path] }

    expect(edges.count).to eq 1
  end

  it "users<->roles<->permissions<->resources" do
    permissions_and_roles
    users_and_groups

    resource = Resource.create(name: 'resource')

    Edge.create(user: @ceo, role: @prod_access)
    Edge.create(role: @prod_access, permission: @reboot_access)
    Edge.create(permission: @reboot_access, resource: resource)

    edges = Edge.users_roles_permissions_resources.sort_by { |v| v[:group_path] }

    expect(edges.count).to eq 1
  end

  it "users<->permissions<->resource" do
    user = User.create(name: "user")
    permission = Permission.create(name: "read")
    resource = Resource.create(name: "resource")

    Edge.create(user: user, permission: permission)
    Edge.create(permission: permission, resource: resource)

    expect(Edge.users_permissions_resources.count).to eq 1
  end
end
