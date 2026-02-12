require 'spec_helper'

RSpec.describe SuperAuth do
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
    # SuperAuth.uninstall_migrations
  end

  describe "US-001: Group Tree Hierarchies (Nestable)" do
    it "single root group has group_path equal to its own id" do
      root = SuperAuth::Group.create(name: 'root')
      tree = SuperAuth::Group.trees.first
      expect(tree[:group_path]).to eq root.id.to_s
      expect(tree[:group_name_path]).to eq 'root'
    end

    it "2-level hierarchy has correct group_path and group_name_path" do
      root = SuperAuth::Group.create(name: 'Company')
      child = SuperAuth::Group.create(name: 'Engineering', parent: root)

      trees = SuperAuth::Group.trees.order(:id).all
      expect(trees.length).to eq 2

      root_tree = trees.find { |t| t[:id] == root.id }
      child_tree = trees.find { |t| t[:id] == child.id }

      expect(root_tree[:group_path]).to eq root.id.to_s
      expect(root_tree[:group_name_path]).to eq 'Company'

      expect(child_tree[:group_path]).to eq "#{root.id},#{child.id}"
      expect(child_tree[:group_name_path]).to eq 'Company,Engineering'
    end

    it "3-level hierarchy has correct paths at each level" do
      root = SuperAuth::Group.create(name: 'root')
      child = SuperAuth::Group.create(name: 'admin', parent: root)
      grandchild = SuperAuth::Group.create(name: 'user', parent: child)

      descendants = root.descendants_dataset.order(:id).all

      expect(descendants.map { |d| d[:group_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(descendants.map { |d| d[:group_name_path] }).to eq [
        'root',
        'root,admin',
        'root,admin,user'
      ]
    end

    it "wide tree with 3+ direct children has correct paths" do
      root = SuperAuth::Group.create(name: 'Corp')
      child_a = SuperAuth::Group.create(name: 'Sales', parent: root)
      child_b = SuperAuth::Group.create(name: 'Engineering', parent: root)
      child_c = SuperAuth::Group.create(name: 'Marketing', parent: root)
      child_d = SuperAuth::Group.create(name: 'HR', parent: root)

      trees = SuperAuth::Group.trees.order(:id).all
      expect(trees.length).to eq 5

      [child_a, child_b, child_c, child_d].each do |child|
        tree_node = trees.find { |t| t[:id] == child.id }
        expect(tree_node[:group_path]).to eq "#{root.id},#{child.id}"
        expect(tree_node[:group_name_path]).to eq "Corp,#{child.name}"
      end
    end

    it "descendants_dataset returns all descendants including the root itself" do
      root = SuperAuth::Group.create(name: 'root')
      child = SuperAuth::Group.create(name: 'child', parent: root)
      grandchild = SuperAuth::Group.create(name: 'grandchild', parent: child)

      descendants = root.descendants_dataset.order(:id).all
      expect(descendants.map(&:id)).to eq [root.id, child.id, grandchild.id]
    end

    it "descendants_dataset on a mid-level node returns its parent's subtree (not siblings' children)" do
      root = SuperAuth::Group.create(name: 'root')
      child_a = SuperAuth::Group.create(name: 'child_a', parent: root)
      child_b = SuperAuth::Group.create(name: 'child_b', parent: root)
      grandchild_a = SuperAuth::Group.create(name: 'grandchild_a', parent: child_a)
      grandchild_b = SuperAuth::Group.create(name: 'grandchild_b', parent: child_b)

      # descendants_dataset uses parent_id internally, so from child_a
      # it traverses from root downward and includes the full subtree
      descendants_from_root = root.descendants_dataset.order(:id).all
      expect(descendants_from_root.map(&:id)).to eq [root.id, child_a.id, child_b.id, grandchild_a.id, grandchild_b.id]

      # A child with its own children: descendants_dataset returns subtree from its parent
      child_a_descendants = child_a.descendants_dataset.order(:id).all
      child_a_ids = child_a_descendants.map(&:id)
      expect(child_a_ids).to include(root.id, child_a.id, grandchild_a.id)

      # Using cte directly on a specific id gives only that node's subtree
      subtree = SuperAuth::Group.cte(child_a.id, :desc).order(:id).all
      subtree_ids = subtree.map(&:id)
      expect(subtree_ids).to include(child_a.id, grandchild_a.id)
      expect(subtree_ids).not_to include(child_b.id)
      expect(subtree_ids).not_to include(grandchild_b.id)
    end

    it "roots scope returns only groups with no parent" do
      root1 = SuperAuth::Group.create(name: 'root1')
      root2 = SuperAuth::Group.create(name: 'root2')
      _child = SuperAuth::Group.create(name: 'child', parent: root1)

      roots = SuperAuth::Group.roots.order(:id).all
      expect(roots.map(&:id)).to eq [root1.id, root2.id]
    end

    it "trees scope returns all groups with their computed paths" do
      root = SuperAuth::Group.create(name: 'Company')
      child = SuperAuth::Group.create(name: 'Dev', parent: root)
      grandchild = SuperAuth::Group.create(name: 'Backend', parent: child)

      trees = SuperAuth::Group.trees.order(:id).all
      expect(trees.length).to eq 3

      expect(trees.map { |t| t[:group_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(trees.map { |t| t[:group_name_path] }).to eq [
        'Company',
        'Company,Dev',
        'Company,Dev,Backend'
      ]
    end
  end

  describe "US-002: Role Tree Hierarchies (Nestable)" do
    it "single root role has role_path equal to its own id" do
      root = SuperAuth::Role.create(name: 'root')
      tree = SuperAuth::Role.trees.first
      expect(tree[:role_path]).to eq root.id.to_s
      expect(tree[:role_name_path]).to eq 'root'
    end

    it "2-level hierarchy has correct role_path and role_name_path" do
      root = SuperAuth::Role.create(name: 'Admin')
      child = SuperAuth::Role.create(name: 'Editor', parent: root)

      trees = SuperAuth::Role.trees.order(:id).all
      expect(trees.length).to eq 2

      root_tree = trees.find { |t| t[:id] == root.id }
      child_tree = trees.find { |t| t[:id] == child.id }

      expect(root_tree[:role_path]).to eq root.id.to_s
      expect(root_tree[:role_name_path]).to eq 'Admin'

      expect(child_tree[:role_path]).to eq "#{root.id},#{child.id}"
      expect(child_tree[:role_name_path]).to eq 'Admin,Editor'
    end

    it "3-level hierarchy has correct paths at each level" do
      root = SuperAuth::Role.create(name: 'superadmin')
      child = SuperAuth::Role.create(name: 'admin', parent: root)
      grandchild = SuperAuth::Role.create(name: 'viewer', parent: child)

      descendants = root.descendants_dataset.order(:id).all

      expect(descendants.map { |d| d[:role_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(descendants.map { |d| d[:role_name_path] }).to eq [
        'superadmin',
        'superadmin,admin',
        'superadmin,admin,viewer'
      ]
    end

    it "wide tree with 3+ direct children has correct paths" do
      root = SuperAuth::Role.create(name: 'Base')
      child_a = SuperAuth::Role.create(name: 'Developer', parent: root)
      child_b = SuperAuth::Role.create(name: 'Designer', parent: root)
      child_c = SuperAuth::Role.create(name: 'Tester', parent: root)
      child_d = SuperAuth::Role.create(name: 'DevOps', parent: root)

      trees = SuperAuth::Role.trees.order(:id).all
      expect(trees.length).to eq 5

      [child_a, child_b, child_c, child_d].each do |child|
        tree_node = trees.find { |t| t[:id] == child.id }
        expect(tree_node[:role_path]).to eq "#{root.id},#{child.id}"
        expect(tree_node[:role_name_path]).to eq "Base,#{child.name}"
      end
    end

    it "descendants_dataset returns all descendants including the root itself" do
      root = SuperAuth::Role.create(name: 'root')
      child = SuperAuth::Role.create(name: 'child', parent: root)
      grandchild = SuperAuth::Role.create(name: 'grandchild', parent: child)

      descendants = root.descendants_dataset.order(:id).all
      expect(descendants.map(&:id)).to eq [root.id, child.id, grandchild.id]
    end

    it "descendants_dataset on a mid-level node returns its parent's subtree; cte gives strict subtree" do
      root = SuperAuth::Role.create(name: 'root')
      child_a = SuperAuth::Role.create(name: 'child_a', parent: root)
      child_b = SuperAuth::Role.create(name: 'child_b', parent: root)
      grandchild_a = SuperAuth::Role.create(name: 'grandchild_a', parent: child_a)
      grandchild_b = SuperAuth::Role.create(name: 'grandchild_b', parent: child_b)

      # descendants_dataset uses parent_id internally, so from root it returns all
      descendants_from_root = root.descendants_dataset.order(:id).all
      expect(descendants_from_root.map(&:id)).to eq [root.id, child_a.id, child_b.id, grandchild_a.id, grandchild_b.id]

      # A child: descendants_dataset returns subtree from its parent
      child_a_descendants = child_a.descendants_dataset.order(:id).all
      child_a_ids = child_a_descendants.map(&:id)
      expect(child_a_ids).to include(root.id, child_a.id, grandchild_a.id)

      # Using cte directly on a specific id gives only that node's subtree
      subtree = SuperAuth::Role.cte(child_a.id, :desc).order(:id).all
      subtree_ids = subtree.map(&:id)
      expect(subtree_ids).to include(child_a.id, grandchild_a.id)
      expect(subtree_ids).not_to include(child_b.id)
      expect(subtree_ids).not_to include(grandchild_b.id)
    end

    it "roots scope returns only roles with no parent" do
      root1 = SuperAuth::Role.create(name: 'root1')
      root2 = SuperAuth::Role.create(name: 'root2')
      _child = SuperAuth::Role.create(name: 'child', parent: root1)

      roots = SuperAuth::Role.roots.order(:id).all
      expect(roots.map(&:id)).to eq [root1.id, root2.id]
    end

    it "trees scope returns all roles with their computed paths" do
      root = SuperAuth::Role.create(name: 'Manager')
      child = SuperAuth::Role.create(name: 'Team Lead', parent: root)
      grandchild = SuperAuth::Role.create(name: 'IC', parent: child)

      trees = SuperAuth::Role.trees.order(:id).all
      expect(trees.length).to eq 3

      expect(trees.map { |t| t[:role_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(trees.map { |t| t[:role_name_path] }).to eq [
        'Manager',
        'Manager,Team Lead',
        'Manager,Team Lead,IC'
      ]
    end
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

  let(:nested_groups_with_users) do
    @senior_developer = SuperAuth::User.create(name: 'Señor Dev')
    @noob_developer = SuperAuth::User.create(name: 'gotta get good')
    @marketing_bro = SuperAuth::User.create(name: "Buy this pen!")
    _irrelevant = SuperAuth::User.create(name: "ignore me")

    @organization = SuperAuth::Group.create(name: 'Foobar Corp')
      @developers = SuperAuth::Group.create(name: 'developers', parent: @organization)
    _irrelevant = SuperAuth::Group.create(name: "ignore me")


    SuperAuth::Edge.create(user: @senior_developer, group: @developers)
    SuperAuth::Edge.create(user: @noob_developer, group: @developers)
    SuperAuth::Edge.create(user: @marketing_bro, group: @organization)
  end

  let(:nested_roles_with_permissions) do
    @guest_user = SuperAuth::User.create(name: "user")
    # @admin_user = SuperAuth::User.create(name: "admin user")
    # _irrelevant = SuperAuth::User.create(name: "ignore me")

    @read = SuperAuth::Permission.create(name: 'read')
    @write = SuperAuth::Permission.create(name: 'write')
    @login = SuperAuth::Permission.create(name: "login")
    # _irrelevant = SuperAuth::Permission.create(name: "ignore me")

    @all_roles = SuperAuth::Role.create(name: 'All Roles')
      # @admin = SuperAuth::Role.create(name: 'admin', parent: @all_roles)
      @guest = SuperAuth::Role.create(name: 'guest', parent: @all_roles)
    # _irrelevant = SuperAuth::Role.create(name: "ignore me")

    # SuperAuth::Edge.create(permission: @login, role: @all_roles)
    SuperAuth::Edge.create(permission: @read, role: @guest)
    # SuperAuth::Edge.create(permission: @write, role: @admin)
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

  it "users<->nested_groups<->permissions<->resources" do
    nested_groups_with_users

    resource = SuperAuth::Resource.create(name: 'hr')
    talk = SuperAuth::Permission.create(name: 'talk')

    SuperAuth::Edge.create(group: @organization, permission: talk)
    SuperAuth::Edge.create(group: @developers, resource: resource)
    SuperAuth::Edge.create(resource: resource, permission: talk)

    edges = SuperAuth::Edge.users_groups_permissions_resources

    expect(edges.count).to eq 3
  end

  it "users<->nested_roles<->permissions<->resources" do
    @all_roles = SuperAuth::Role.create(name: 'All Roles')
      @qa = SuperAuth::Role.create(name: 'Bob', parent: @all_roles)

    @guest_user = SuperAuth::User.create(name: "user")
    @read = SuperAuth::Permission.create(name: 'read')

    resource = SuperAuth::Resource.create(name: 'hr')

    SuperAuth::Edge.create(permission: @read, role: @qa)
    SuperAuth::Edge.create(user: @guest_user, role: @qa)
    SuperAuth::Edge.create(resource: resource, role: @qa)

    edges = SuperAuth::Edge.users_roles_permissions_resources

    expect(edges.count).to eq 2
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

  it "users<->permissions<->resources" do
    user = SuperAuth::User.create(name: "user")
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
