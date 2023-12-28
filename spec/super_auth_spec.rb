# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SuperAuth do
  Group = SuperAuth::Group
  User = SuperAuth::User
  Edge = SuperAuth::Edge
  Permission = SuperAuth::Permission
  Role = SuperAuth::Role

  let(:db) { Sequel::Model.db }

  before do
    db[:edges].delete
    db[:groups].delete
    db[:users].delete
    db[:permissions].delete
    db[:roles].delete
  end

  it "can create a group tree" do
    root_group = Group.create(name: 'root')
      admin_group = Group.create(name: 'admin', parent: root_group)
        user_group = Group.create(name: 'user', parent: admin_group)

    descendants = root_group.descendants.sort_by(&:id)
    expect(descendants).to match_array([root_group, user_group, admin_group])

    expect(descendants.map { |d| d[:group_path] }).to eq ["#{root_group.id}", "#{root_group.id},#{admin_group.id}", "#{root_group.id},#{admin_group.id},#{user_group.id}"]
  end

  it "can merge users with groups" do
    ceo = User.create(name: 'CEO')
    senior_developer = User.create(name: 'Señor Dev')
    noob_developer = User.create(name: 'gotta get good')
    marketing_bro = User.create(name: "Buy this pen!")

    organization = Group.create(name: 'Foobar Corp')
      marketing = Group.create(name: 'marketing', parent: organization)

      developers = Group.create(name: 'developers', parent: organization)
        feature1 = Group.create(name: 'feature1', parent: developers)
        _feature = Group.create(name: 'feature2', parent: developers)

    Edge.create(user: ceo, group: organization)
    Edge.create(user: senior_developer, group: developers)
    Edge.create(user: marketing_bro, group: marketing)
    Edge.create(user: noob_developer, group: feature1)

    ceo_res, senior_developer_res, noob_developer_res, marketing_bro_res = User.with_groups.all.sort_by(&:id)
    [
      # result               user_id,                group_id,        group_name     parent_id,       group_path,                                            group_name_path
      [ceo_res,              ceo.id,                 organization.id, 'Foobar Corp', nil,             "#{organization.id}",                                 "Foobar Corp"],
      [senior_developer_res, senior_developer.id,    developers.id,   'developers',  organization.id, "#{organization.id},#{developers.id}",                "Foobar Corp,developers"],
      [noob_developer_res,   noob_developer.id,      feature1.id,     'feature1',    developers.id,   "#{organization.id},#{developers.id},#{feature1.id}", "Foobar Corp,developers,feature1"],
      [marketing_bro_res,    marketing_bro.id,       marketing.id,    'marketing',   organization.id, "#{organization.id},#{marketing.id}",                 "Foobar Corp,marketing"],
    ].each do |res, user_id, group_id, group_name, parent_id, group_path, group_name_path|
      expect(res.id.to_s).to eq user_id.to_s
      expect(res[:group_id].to_s).to eq group_id.to_s
      expect(res[:group_name]).to eq group_name
      expect(res[:parent_id].to_s).to eq parent_id.to_s
      expect(res[:group_path]).to eq group_path
      expect(res[:group_name_path]).to eq group_name_path
    end
  end

  it "can merge permissions with roles" do
    read_access = Permission.create(name: 'read')
    write_access = Permission.create(name: 'write')
    reboot_access = Permission.create(name: 'reboot')
    invoice = Permission.create(name: 'invoice')

    employee  = Role.create(name: 'employee')
      accounting = Role.create(name: 'accounting', parent: employee)

      prod_access = Role.create(name: 'production support', parent: employee)
        web = Role.create(name: 'web', parent: prod_access)
        db1 = Role.create(name: 'db1', parent: prod_access)
        db2 = Role.create(name: 'db2', parent: prod_access)

    Edge.create(role: prod_access, permission: read_access)
    Edge.create(role: prod_access, permission: write_access)
    Edge.create(role: prod_access, permission: reboot_access)
    Edge.create(role: accounting, permission: invoice)

    read_res, write_res, reboot_res, invoice_res = Permission.with_roles.all.sort_by(&:id)
    [
      # result      permission_id,    role_id,        role_name             parent_id,      role_path,                          role_name_path
      [read_res,    read_access.id,   prod_access.id, 'production support', employee.id,    "#{employee.id},#{prod_access.id}", "employee,production support"],
      [write_res,   write_access.id,  prod_access.id, 'production support', employee.id,    "#{employee.id},#{prod_access.id}", "employee,production support"],
      [reboot_res,  reboot_access.id, prod_access.id, 'production support', employee.id,    "#{employee.id},#{prod_access.id}", "employee,production support"],
      [invoice_res, invoice.id,       accounting.id,  'accounting',         employee.id,    "#{employee.id},#{accounting.id}",  "employee,accounting"],
    ].each do |res, permission_id, role_id, role_name, parent_id, role_path, role_name_path|
      expect(res.id.to_s).to eq permission_id.to_s
      expect(res[:role_id].to_s).to eq role_id.to_s
      expect(res[:role_name]).to eq role_name
      expect(res[:parent_id].to_s).to eq parent_id.to_s
      expect(res[:role_path]).to eq role_path
      expect(res[:role_name_path]).to eq role_name_path
    end
  end
end
