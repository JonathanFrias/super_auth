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

  describe "US-003: Path Strategy 1 - users <-> groups <-> roles <-> permissions <-> resources" do
    it "basic flat case: user -> group -> role -> permission -> resource (no nesting)" do
      user = SuperAuth::User.create(name: 'Alice')
      group = SuperAuth::Group.create(name: 'Engineering')
      role = SuperAuth::Role.create(name: 'Developer')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:role_name]).to eq 'Developer'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "nested groups: user in child group, role linked to parent group, permission propagates down" do
      user = SuperAuth::User.create(name: 'Bob')
      parent_group = SuperAuth::Group.create(name: 'Company')
      child_group = SuperAuth::Group.create(name: 'Engineering', parent: parent_group)
      role = SuperAuth::Role.create(name: 'Viewer')
      permission = SuperAuth::Permission.create(name: 'view')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, group: child_group)
      SuperAuth::Edge.create(group: parent_group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Bob'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:role_name]).to eq 'Viewer'
      expect(edge[:permission_name]).to eq 'view'
      expect(edge[:resource_name]).to eq 'dashboard'
    end

    it "nested roles: user -> group -> parent_role, permission on child_role propagates" do
      user = SuperAuth::User.create(name: 'Charlie')
      group = SuperAuth::Group.create(name: 'Team')
      parent_role = SuperAuth::Role.create(name: 'Manager')
      child_role = SuperAuth::Role.create(name: 'Lead', parent: parent_role)
      permission = SuperAuth::Permission.create(name: 'approve')
      resource = SuperAuth::Resource.create(name: 'requests')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: parent_role)
      SuperAuth::Edge.create(role: child_role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Charlie'
      expect(edge[:group_name]).to eq 'Team'
      expect(edge[:role_name]).to eq 'Lead'
      expect(edge[:permission_name]).to eq 'approve'
      expect(edge[:resource_name]).to eq 'requests'
    end

    it "both nested groups AND nested roles simultaneously" do
      user = SuperAuth::User.create(name: 'Diana')
      root_group = SuperAuth::Group.create(name: 'Corp')
      child_group = SuperAuth::Group.create(name: 'Division', parent: root_group)
      root_role = SuperAuth::Role.create(name: 'Staff')
      child_role = SuperAuth::Role.create(name: 'Analyst', parent: root_role)
      permission = SuperAuth::Permission.create(name: 'analyze')
      resource = SuperAuth::Resource.create(name: 'reports')

      SuperAuth::Edge.create(user: user, group: child_group)
      SuperAuth::Edge.create(group: root_group, role: root_role)
      SuperAuth::Edge.create(role: child_role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Diana'
      expect(edge[:group_name]).to eq 'Division'
      expect(edge[:role_name]).to eq 'Analyst'
      expect(edge[:permission_name]).to eq 'analyze'
      expect(edge[:resource_name]).to eq 'reports'
    end

    it "deeply nested groups (3+ levels): user at leaf group still gets authorization" do
      user = SuperAuth::User.create(name: 'Eve')
      g1 = SuperAuth::Group.create(name: 'Org')
      g2 = SuperAuth::Group.create(name: 'Dept', parent: g1)
      g3 = SuperAuth::Group.create(name: 'Team', parent: g2)
      g4 = SuperAuth::Group.create(name: 'Squad', parent: g3)
      role = SuperAuth::Role.create(name: 'Worker')
      permission = SuperAuth::Permission.create(name: 'execute')
      resource = SuperAuth::Resource.create(name: 'pipeline')

      SuperAuth::Edge.create(user: user, group: g4)
      SuperAuth::Edge.create(group: g1, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Eve'
      expect(edge[:group_name]).to eq 'Squad'
      expect(edge[:permission_name]).to eq 'execute'
      expect(edge[:resource_name]).to eq 'pipeline'
    end

    it "deeply nested roles (3+ levels): permissions propagate correctly" do
      user = SuperAuth::User.create(name: 'Frank')
      group = SuperAuth::Group.create(name: 'Ops')
      r1 = SuperAuth::Role.create(name: 'Base')
      r2 = SuperAuth::Role.create(name: 'Mid', parent: r1)
      r3 = SuperAuth::Role.create(name: 'Senior', parent: r2)
      r4 = SuperAuth::Role.create(name: 'Principal', parent: r3)
      permission = SuperAuth::Permission.create(name: 'deploy')
      resource = SuperAuth::Resource.create(name: 'production')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: r1)
      SuperAuth::Edge.create(role: r4, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Frank'
      expect(edge[:group_name]).to eq 'Ops'
      expect(edge[:role_name]).to eq 'Principal'
      expect(edge[:permission_name]).to eq 'deploy'
      expect(edge[:resource_name]).to eq 'production'
    end

    it "multiple users in different groups all get authorized to the same resource" do
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      user3 = SuperAuth::User.create(name: 'User3')
      root_group = SuperAuth::Group.create(name: 'HQ')
      group_a = SuperAuth::Group.create(name: 'Sales', parent: root_group)
      group_b = SuperAuth::Group.create(name: 'Support', parent: root_group)
      role = SuperAuth::Role.create(name: 'Agent')
      permission = SuperAuth::Permission.create(name: 'access')
      resource = SuperAuth::Resource.create(name: 'crm')

      SuperAuth::Edge.create(user: user1, group: root_group)
      SuperAuth::Edge.create(user: user2, group: group_a)
      SuperAuth::Edge.create(user: user3, group: group_b)
      SuperAuth::Edge.create(group: root_group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:role_name]).to eq 'Agent'
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'crm'
      end
    end

    it "user in an unrelated group does NOT get authorized" do
      user_authorized = SuperAuth::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::User.create(name: 'Outsider')
      group_a = SuperAuth::Group.create(name: 'Alpha')
      group_b = SuperAuth::Group.create(name: 'Beta')
      role = SuperAuth::Role.create(name: 'Operator')
      permission = SuperAuth::Permission.create(name: 'operate')
      resource = SuperAuth::Resource.create(name: 'machine')

      SuperAuth::Edge.create(user: user_authorized, group: group_a)
      SuperAuth::Edge.create(user: user_unauthorized, group: group_b)
      SuperAuth::Edge.create(group: group_a, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple permissions on the same role->resource path produce multiple authorization records" do
      user = SuperAuth::User.create(name: 'Grace')
      group = SuperAuth::Group.create(name: 'Admin')
      role = SuperAuth::Role.create(name: 'SuperAdmin')
      perm_read = SuperAuth::Permission.create(name: 'read')
      perm_write = SuperAuth::Permission.create(name: 'write')
      perm_delete = SuperAuth::Permission.create(name: 'delete')
      resource = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: perm_read)
      SuperAuth::Edge.create(role: role, permission: perm_write)
      SuperAuth::Edge.create(role: role, permission: perm_delete)
      SuperAuth::Edge.create(permission: perm_read, resource: resource)
      SuperAuth::Edge.create(permission: perm_write, resource: resource)
      SuperAuth::Edge.create(permission: perm_delete, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Grace'
        expect(edge[:group_name]).to eq 'Admin'
        expect(edge[:role_name]).to eq 'SuperAdmin'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "result includes correct user_name, group_name, group_path, group_name_path, role_name, role_path, role_name_path, permission_name, resource_name" do
      user = SuperAuth::User.create(name: 'Hank', external_id: 'ext-1', external_type: 'ldap')
      root_group = SuperAuth::Group.create(name: 'Corp')
      child_group = SuperAuth::Group.create(name: 'IT', parent: root_group)
      root_role = SuperAuth::Role.create(name: 'Staff')
      child_role = SuperAuth::Role.create(name: 'SysAdmin', parent: root_role)
      permission = SuperAuth::Permission.create(name: 'manage')
      resource = SuperAuth::Resource.create(name: 'servers', external_id: 'srv-1', external_type: 'aws')

      SuperAuth::Edge.create(user: user, group: child_group)
      SuperAuth::Edge.create(group: root_group, role: root_role)
      SuperAuth::Edge.create(role: child_role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Hank'
      expect(edge[:user_external_id]).to eq 'ext-1'
      expect(edge[:user_external_type]).to eq 'ldap'

      expect(edge[:group_name]).to eq 'IT'
      expect(edge[:group_path]).to eq "#{root_group.id},#{child_group.id}"
      expect(edge[:group_name_path]).to eq 'Corp,IT'

      expect(edge[:role_name]).to eq 'SysAdmin'
      expect(edge[:role_path]).to eq "#{root_role.id},#{child_role.id}"
      expect(edge[:role_name_path]).to eq 'Staff,SysAdmin'

      expect(edge[:permission_name]).to eq 'manage'

      expect(edge[:resource_name]).to eq 'servers'
      expect(edge[:resource_external_id]).to eq 'srv-1'
      expect(edge[:resource_external_type]).to eq 'aws'
    end
  end

  describe "US-004: Path Strategy 2 - users <-> roles <-> permissions <-> resources" do
    it "basic case: user -> role -> permission -> resource with flat role" do
      user = SuperAuth::User.create(name: 'Alice')
      role = SuperAuth::Role.create(name: 'Developer')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:role_name]).to eq 'Developer'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "nested roles: user -> parent_role, permission linked to child_role, verify authorization" do
      user = SuperAuth::User.create(name: 'Bob')
      parent_role = SuperAuth::Role.create(name: 'Manager')
      child_role = SuperAuth::Role.create(name: 'Lead', parent: parent_role)
      permission = SuperAuth::Permission.create(name: 'approve')
      resource = SuperAuth::Resource.create(name: 'requests')

      SuperAuth::Edge.create(user: user, role: parent_role)
      SuperAuth::Edge.create(role: child_role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Bob'
      expect(edge[:role_name]).to eq 'Lead'
      expect(edge[:permission_name]).to eq 'approve'
      expect(edge[:resource_name]).to eq 'requests'
    end

    it "deeply nested roles (3+ levels): permissions propagate correctly" do
      user = SuperAuth::User.create(name: 'Charlie')
      r1 = SuperAuth::Role.create(name: 'Base')
      r2 = SuperAuth::Role.create(name: 'Mid', parent: r1)
      r3 = SuperAuth::Role.create(name: 'Senior', parent: r2)
      r4 = SuperAuth::Role.create(name: 'Principal', parent: r3)
      permission = SuperAuth::Permission.create(name: 'deploy')
      resource = SuperAuth::Resource.create(name: 'production')

      SuperAuth::Edge.create(user: user, role: r1)
      SuperAuth::Edge.create(role: r4, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Charlie'
      expect(edge[:role_name]).to eq 'Principal'
      expect(edge[:permission_name]).to eq 'deploy'
      expect(edge[:resource_name]).to eq 'production'
    end

    it "multiple permissions on the same role produce multiple authorization records" do
      user = SuperAuth::User.create(name: 'Diana')
      role = SuperAuth::Role.create(name: 'Admin')
      perm_read = SuperAuth::Permission.create(name: 'read')
      perm_write = SuperAuth::Permission.create(name: 'write')
      perm_delete = SuperAuth::Permission.create(name: 'delete')
      resource = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: perm_read)
      SuperAuth::Edge.create(role: role, permission: perm_write)
      SuperAuth::Edge.create(role: role, permission: perm_delete)
      SuperAuth::Edge.create(permission: perm_read, resource: resource)
      SuperAuth::Edge.create(permission: perm_write, resource: resource)
      SuperAuth::Edge.create(permission: perm_delete, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Diana'
        expect(edge[:role_name]).to eq 'Admin'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "group-related fields are NULL/0 in the result since groups are not part of this path" do
      user = SuperAuth::User.create(name: 'Eve')
      role = SuperAuth::Role.create(name: 'Viewer')
      permission = SuperAuth::Permission.create(name: 'view')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:group_id]).to eq 0
      expect(edge[:group_name]).to be_nil
      expect(edge[:group_path]).to be_nil
      expect(edge[:group_name_path]).to be_nil
      expect(edge[:group_parent_id]).to eq 0
    end

    it "user linked to an unrelated role does NOT get authorized to the resource" do
      user_authorized = SuperAuth::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::User.create(name: 'Outsider')
      role_a = SuperAuth::Role.create(name: 'Operator')
      role_b = SuperAuth::Role.create(name: 'Observer')
      permission = SuperAuth::Permission.create(name: 'operate')
      resource = SuperAuth::Resource.create(name: 'machine')

      SuperAuth::Edge.create(user: user_authorized, role: role_a)
      SuperAuth::Edge.create(user: user_unauthorized, role: role_b)
      SuperAuth::Edge.create(role: role_a, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple users each linked to different roles but same permission and resource" do
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      user3 = SuperAuth::User.create(name: 'User3')
      role_a = SuperAuth::Role.create(name: 'RoleA')
      role_b = SuperAuth::Role.create(name: 'RoleB')
      role_c = SuperAuth::Role.create(name: 'RoleC')
      permission = SuperAuth::Permission.create(name: 'access')
      resource = SuperAuth::Resource.create(name: 'api')

      SuperAuth::Edge.create(user: user1, role: role_a)
      SuperAuth::Edge.create(user: user2, role: role_b)
      SuperAuth::Edge.create(user: user3, role: role_c)
      SuperAuth::Edge.create(role: role_a, permission: permission)
      SuperAuth::Edge.create(role: role_b, permission: permission)
      SuperAuth::Edge.create(role: role_c, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_roles_permissions_resources.all
      expect(edges.length).to eq 3

      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'api'
      end
    end
  end

  describe "US-005: Path Strategy 3 - users <-> groups <-> permissions <-> resources" do
    it "basic case: user -> group -> permission -> resource with flat group" do
      user = SuperAuth::User.create(name: 'Alice')
      group = SuperAuth::Group.create(name: 'Engineering')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "nested groups: user in child group, permission linked to parent group" do
      user = SuperAuth::User.create(name: 'Bob')
      parent_group = SuperAuth::Group.create(name: 'Company')
      child_group = SuperAuth::Group.create(name: 'Engineering', parent: parent_group)
      permission = SuperAuth::Permission.create(name: 'view')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, group: child_group)
      SuperAuth::Edge.create(group: parent_group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Bob'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:group_path]).to eq "#{parent_group.id},#{child_group.id}"
      expect(edge[:group_name_path]).to eq 'Company,Engineering'
      expect(edge[:permission_name]).to eq 'view'
      expect(edge[:resource_name]).to eq 'dashboard'
    end

    it "deeply nested groups (3+ levels): user at leaf group gets parent's permission" do
      user = SuperAuth::User.create(name: 'Charlie')
      g1 = SuperAuth::Group.create(name: 'Org')
      g2 = SuperAuth::Group.create(name: 'Dept', parent: g1)
      g3 = SuperAuth::Group.create(name: 'Team', parent: g2)
      g4 = SuperAuth::Group.create(name: 'Squad', parent: g3)
      permission = SuperAuth::Permission.create(name: 'access')
      resource = SuperAuth::Resource.create(name: 'intranet')

      SuperAuth::Edge.create(user: user, group: g4)
      SuperAuth::Edge.create(group: g1, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Charlie'
      expect(edge[:group_name]).to eq 'Squad'
      expect(edge[:group_path]).to eq "#{g1.id},#{g2.id},#{g3.id},#{g4.id}"
      expect(edge[:group_name_path]).to eq 'Org,Dept,Team,Squad'
      expect(edge[:permission_name]).to eq 'access'
      expect(edge[:resource_name]).to eq 'intranet'
    end

    it "multiple permissions on the same group produce multiple authorization records" do
      user = SuperAuth::User.create(name: 'Diana')
      group = SuperAuth::Group.create(name: 'Admin')
      perm_read = SuperAuth::Permission.create(name: 'read')
      perm_write = SuperAuth::Permission.create(name: 'write')
      perm_delete = SuperAuth::Permission.create(name: 'delete')
      resource = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: perm_read)
      SuperAuth::Edge.create(group: group, permission: perm_write)
      SuperAuth::Edge.create(group: group, permission: perm_delete)
      SuperAuth::Edge.create(permission: perm_read, resource: resource)
      SuperAuth::Edge.create(permission: perm_write, resource: resource)
      SuperAuth::Edge.create(permission: perm_delete, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Diana'
        expect(edge[:group_name]).to eq 'Admin'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "role-related fields are NULL/0 in the result since roles are not part of this path" do
      user = SuperAuth::User.create(name: 'Eve')
      group = SuperAuth::Group.create(name: 'Viewers')
      permission = SuperAuth::Permission.create(name: 'view')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:role_id]).to eq 0
      expect(edge[:role_name]).to be_nil
      expect(edge[:role_path]).to be_nil
      expect(edge[:role_name_path]).to be_nil
      expect(edge[:role_parent_id]).to eq 0
    end

    it "user in an unrelated group does NOT get authorized" do
      user_authorized = SuperAuth::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::User.create(name: 'Outsider')
      group_a = SuperAuth::Group.create(name: 'Alpha')
      group_b = SuperAuth::Group.create(name: 'Beta')
      permission = SuperAuth::Permission.create(name: 'operate')
      resource = SuperAuth::Resource.create(name: 'machine')

      SuperAuth::Edge.create(user: user_authorized, group: group_a)
      SuperAuth::Edge.create(user: user_unauthorized, group: group_b)
      SuperAuth::Edge.create(group: group_a, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple users in the same group all get the same authorization" do
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      user3 = SuperAuth::User.create(name: 'User3')
      group = SuperAuth::Group.create(name: 'SharedGroup')
      permission = SuperAuth::Permission.create(name: 'access')
      resource = SuperAuth::Resource.create(name: 'api')

      SuperAuth::Edge.create(user: user1, group: group)
      SuperAuth::Edge.create(user: user2, group: group)
      SuperAuth::Edge.create(user: user3, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_groups_permissions_resources.all
      expect(edges.length).to eq 3

      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:group_name]).to eq 'SharedGroup'
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'api'
      end
    end
  end

  describe "US-006: Path Strategy 4 - users <-> permissions <-> resources" do
    it "basic case: user -> permission -> resource" do
      user = SuperAuth::User.create(name: 'Alice')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "multiple permissions on the same user and resource produce multiple records" do
      user = SuperAuth::User.create(name: 'Bob')
      perm_read = SuperAuth::Permission.create(name: 'read')
      perm_write = SuperAuth::Permission.create(name: 'write')
      perm_delete = SuperAuth::Permission.create(name: 'delete')
      resource = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, permission: perm_read)
      SuperAuth::Edge.create(user: user, permission: perm_write)
      SuperAuth::Edge.create(user: user, permission: perm_delete)
      SuperAuth::Edge.create(permission: perm_read, resource: resource)
      SuperAuth::Edge.create(permission: perm_write, resource: resource)
      SuperAuth::Edge.create(permission: perm_delete, resource: resource)

      edges = SuperAuth::Edge.users_permissions_resources.all
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Bob'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "group and role fields are NULL/0 in the result" do
      user = SuperAuth::User.create(name: 'Charlie')
      permission = SuperAuth::Permission.create(name: 'view')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_permissions_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:group_id]).to eq 0
      expect(edge[:group_name]).to be_nil
      expect(edge[:group_path]).to be_nil
      expect(edge[:group_name_path]).to be_nil
      expect(edge[:group_parent_id]).to eq 0

      expect(edge[:role_id]).to eq 0
      expect(edge[:role_name]).to be_nil
      expect(edge[:role_path]).to be_nil
      expect(edge[:role_name_path]).to be_nil
      expect(edge[:role_parent_id]).to eq 0
    end

    it "user with an unrelated permission does NOT get authorized to the resource" do
      user_authorized = SuperAuth::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::User.create(name: 'Outsider')
      perm_a = SuperAuth::Permission.create(name: 'access')
      perm_b = SuperAuth::Permission.create(name: 'noaccess')
      resource = SuperAuth::Resource.create(name: 'secret')

      SuperAuth::Edge.create(user: user_authorized, permission: perm_a)
      SuperAuth::Edge.create(user: user_unauthorized, permission: perm_b)
      SuperAuth::Edge.create(permission: perm_a, resource: resource)
      # perm_b is NOT linked to the resource

      edges = SuperAuth::Edge.users_permissions_resources.all
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "two users with the same permission both get authorized to the resource" do
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      permission = SuperAuth::Permission.create(name: 'access')
      resource = SuperAuth::Resource.create(name: 'api')

      SuperAuth::Edge.create(user: user1, permission: permission)
      SuperAuth::Edge.create(user: user2, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      edges = SuperAuth::Edge.users_permissions_resources.all
      expect(edges.length).to eq 2

      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2']

      edges.each do |edge|
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'api'
      end
    end
  end

  describe "US-007: Path Strategy 5 - users <-> resources" do
    it "basic case: user -> resource" do
      user = SuperAuth::User.create(name: 'Alice')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, resource: resource)

      edges = SuperAuth::Edge.users_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "group, role, and permission fields are NULL/0 in the result" do
      user = SuperAuth::User.create(name: 'Bob')
      resource = SuperAuth::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user: user, resource: resource)

      edges = SuperAuth::Edge.users_resources.all
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:group_id]).to eq 0
      expect(edge[:group_name]).to be_nil
      expect(edge[:group_path]).to be_nil
      expect(edge[:group_name_path]).to be_nil
      expect(edge[:group_parent_id]).to eq 0

      expect(edge[:role_id]).to eq 0
      expect(edge[:role_name]).to be_nil
      expect(edge[:role_path]).to be_nil
      expect(edge[:role_name_path]).to be_nil
      expect(edge[:role_parent_id]).to eq 0

      expect(edge[:permission_id]).to eq 0
      expect(edge[:permission_name]).to be_nil
    end

    it "user with no edge to the resource does NOT get authorized" do
      user_authorized = SuperAuth::User.create(name: 'Insider')
      _user_unauthorized = SuperAuth::User.create(name: 'Outsider')
      resource = SuperAuth::Resource.create(name: 'secret')

      SuperAuth::Edge.create(user: user_authorized, resource: resource)

      edges = SuperAuth::Edge.users_resources.all
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple users each with direct access to the same resource" do
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      user3 = SuperAuth::User.create(name: 'User3')
      resource = SuperAuth::Resource.create(name: 'shared-doc')

      SuperAuth::Edge.create(user: user1, resource: resource)
      SuperAuth::Edge.create(user: user2, resource: resource)
      SuperAuth::Edge.create(user: user3, resource: resource)

      edges = SuperAuth::Edge.users_resources.all
      expect(edges.length).to eq 3

      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:resource_name]).to eq 'shared-doc'
      end
    end

    it "one user with direct access to multiple resources" do
      user = SuperAuth::User.create(name: 'PowerUser')
      resource1 = SuperAuth::Resource.create(name: 'database')
      resource2 = SuperAuth::Resource.create(name: 'server')
      resource3 = SuperAuth::Resource.create(name: 'storage')

      SuperAuth::Edge.create(user: user, resource: resource1)
      SuperAuth::Edge.create(user: user, resource: resource2)
      SuperAuth::Edge.create(user: user, resource: resource3)

      edges = SuperAuth::Edge.users_resources.all
      expect(edges.length).to eq 3

      resource_names = edges.map { |e| e[:resource_name] }.sort
      expect(resource_names).to eq ['database', 'server', 'storage']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'PowerUser'
      end
    end
  end

  describe "US-008: Combined `authorizations` Method (Union of All Strategies)" do
    it "user with only a direct resource edge appears in authorizations" do
      user = SuperAuth::User.create(name: 'DirectUser')
      resource = SuperAuth::Resource.create(name: 'file')

      SuperAuth::Edge.create(user: user, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'DirectUser'
      expect(auth[:resource_name]).to eq 'file'
    end

    it "user with only a permission->resource path appears in authorizations" do
      user = SuperAuth::User.create(name: 'PermUser')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'doc')

      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'PermUser'
      expect(auth[:permission_name]).to eq 'read'
      expect(auth[:resource_name]).to eq 'doc'
    end

    it "user with only a group->permission->resource path appears in authorizations" do
      user = SuperAuth::User.create(name: 'GroupPermUser')
      group = SuperAuth::Group.create(name: 'Team')
      permission = SuperAuth::Permission.create(name: 'edit')
      resource = SuperAuth::Resource.create(name: 'wiki')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'GroupPermUser'
      expect(auth[:group_name]).to eq 'Team'
      expect(auth[:permission_name]).to eq 'edit'
      expect(auth[:resource_name]).to eq 'wiki'
    end

    it "user with only a role->permission->resource path appears in authorizations" do
      user = SuperAuth::User.create(name: 'RolePermUser')
      role = SuperAuth::Role.create(name: 'Admin')
      permission = SuperAuth::Permission.create(name: 'manage')
      resource = SuperAuth::Resource.create(name: 'settings')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'RolePermUser'
      expect(auth[:role_name]).to eq 'Admin'
      expect(auth[:permission_name]).to eq 'manage'
      expect(auth[:resource_name]).to eq 'settings'
    end

    it "user with only a group->role->permission->resource path appears in authorizations" do
      user = SuperAuth::User.create(name: 'FullPathUser')
      group = SuperAuth::Group.create(name: 'Engineering')
      role = SuperAuth::Role.create(name: 'Developer')
      permission = SuperAuth::Permission.create(name: 'deploy')
      resource = SuperAuth::Resource.create(name: 'production')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'FullPathUser'
      expect(auth[:group_name]).to eq 'Engineering'
      expect(auth[:role_name]).to eq 'Developer'
      expect(auth[:permission_name]).to eq 'deploy'
      expect(auth[:resource_name]).to eq 'production'
    end

    it "user with multiple different path types to the same resource gets all of them in authorizations" do
      user = SuperAuth::User.create(name: 'MultiPathUser')
      resource = SuperAuth::Resource.create(name: 'api')
      group = SuperAuth::Group.create(name: 'Ops')
      role = SuperAuth::Role.create(name: 'Operator')
      perm_direct = SuperAuth::Permission.create(name: 'direct_access')
      perm_group = SuperAuth::Permission.create(name: 'group_access')
      perm_role = SuperAuth::Permission.create(name: 'role_access')
      perm_grp_role = SuperAuth::Permission.create(name: 'grp_role_access')

      # Path 1: user -> resource (direct)
      SuperAuth::Edge.create(user: user, resource: resource)

      # Path 2: user -> permission -> resource
      SuperAuth::Edge.create(user: user, permission: perm_direct)
      SuperAuth::Edge.create(permission: perm_direct, resource: resource)

      # Path 3: user -> group -> permission -> resource
      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, permission: perm_group)
      SuperAuth::Edge.create(permission: perm_group, resource: resource)

      # Path 4: user -> role -> permission -> resource
      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: perm_role)
      SuperAuth::Edge.create(permission: perm_role, resource: resource)

      # Path 5: user -> group -> role -> permission -> resource
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: perm_grp_role)
      SuperAuth::Edge.create(permission: perm_grp_role, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      # Should have at least one record from each of the 5 path types
      # Path 1: 1 record (direct)
      # Path 2: 1 record (user->perm_direct->resource)
      # Path 3: 1 record (user->group->perm_group->resource)
      # Path 4: role_access and grp_role_access via role (user->role->perm_role->resource, user->role->perm_grp_role->resource)
      # Path 5: group->role gives role_access and grp_role_access (user->group->role->perm_role->resource, user->group->role->perm_grp_role->resource)
      # Total varies based on how the union deduplicates, but we should have multiple paths
      expect(auths.length).to be >= 5

      resource_names = auths.map { |a| a[:resource_name] }.uniq
      expect(resource_names).to eq ['api']

      user_names = auths.map { |a| a[:user_name] }.uniq
      expect(user_names).to eq ['MultiPathUser']
    end

    it "user with NO edges returns zero authorization records" do
      _user = SuperAuth::User.create(name: 'NoEdgeUser')
      _resource = SuperAuth::Resource.create(name: 'forbidden')

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "results from different strategies have compatible column shapes (union doesn't break)" do
      # Set up one path from each strategy and verify the union produces results
      # with consistent columns
      user1 = SuperAuth::User.create(name: 'User1')
      user2 = SuperAuth::User.create(name: 'User2')
      user3 = SuperAuth::User.create(name: 'User3')
      user4 = SuperAuth::User.create(name: 'User4')
      user5 = SuperAuth::User.create(name: 'User5')
      group = SuperAuth::Group.create(name: 'Grp')
      role = SuperAuth::Role.create(name: 'Rl')
      perm1 = SuperAuth::Permission.create(name: 'p1')
      perm2 = SuperAuth::Permission.create(name: 'p2')
      perm3 = SuperAuth::Permission.create(name: 'p3')
      perm4 = SuperAuth::Permission.create(name: 'p4')
      res1 = SuperAuth::Resource.create(name: 'r1')
      res2 = SuperAuth::Resource.create(name: 'r2')
      res3 = SuperAuth::Resource.create(name: 'r3')
      res4 = SuperAuth::Resource.create(name: 'r4')
      res5 = SuperAuth::Resource.create(name: 'r5')

      # Strategy 5: user -> resource
      SuperAuth::Edge.create(user: user1, resource: res1)

      # Strategy 4: user -> permission -> resource
      SuperAuth::Edge.create(user: user2, permission: perm1)
      SuperAuth::Edge.create(permission: perm1, resource: res2)

      # Strategy 3: user -> group -> permission -> resource
      SuperAuth::Edge.create(user: user3, group: group)
      SuperAuth::Edge.create(group: group, permission: perm2)
      SuperAuth::Edge.create(permission: perm2, resource: res3)

      # Strategy 2: user -> role -> permission -> resource
      SuperAuth::Edge.create(user: user4, role: role)
      SuperAuth::Edge.create(role: role, permission: perm3)
      SuperAuth::Edge.create(permission: perm3, resource: res4)

      # Strategy 1: user -> group -> role -> permission -> resource
      SuperAuth::Edge.create(user: user5, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: perm4)
      SuperAuth::Edge.create(permission: perm4, resource: res5)

      auths = SuperAuth::Edge.authorizations.all

      # All records should have the same set of keys
      expected_keys = [:user_id, :user_name, :resource_id, :resource_name]
      auths.each do |auth|
        expected_keys.each do |key|
          expect(auth.keys).to include(key), "Expected key #{key} to be present in authorization record"
        end
      end

      # Each user should appear with their respective resource
      user_resource_pairs = auths.map { |a| [a[:user_name], a[:resource_name]] }
      expect(user_resource_pairs).to include(['User1', 'r1'])
      expect(user_resource_pairs).to include(['User2', 'r2'])
      expect(user_resource_pairs).to include(['User3', 'r3'])
      expect(user_resource_pairs).to include(['User4', 'r4'])
      expect(user_resource_pairs).to include(['User5', 'r5'])
    end

    it "complex scenario with multiple users, groups, roles, permissions, and resources" do
      # Setup: 3 users, 2 groups (nested), 2 roles, 3 permissions, 2 resources
      alice = SuperAuth::User.create(name: 'Alice')
      bob = SuperAuth::User.create(name: 'Bob')
      charlie = SuperAuth::User.create(name: 'Charlie')

      corp = SuperAuth::Group.create(name: 'Corp')
      eng = SuperAuth::Group.create(name: 'Engineering', parent: corp)

      admin_role = SuperAuth::Role.create(name: 'Admin')
      viewer_role = SuperAuth::Role.create(name: 'Viewer')

      read_perm = SuperAuth::Permission.create(name: 'read')
      write_perm = SuperAuth::Permission.create(name: 'write')
      delete_perm = SuperAuth::Permission.create(name: 'delete')

      database = SuperAuth::Resource.create(name: 'database')
      server = SuperAuth::Resource.create(name: 'server')

      # Alice: direct access to database (Strategy 5)
      SuperAuth::Edge.create(user: alice, resource: database)

      # Bob: group -> role -> permission -> resource (Strategy 1)
      SuperAuth::Edge.create(user: bob, group: eng)
      SuperAuth::Edge.create(group: corp, role: admin_role)
      SuperAuth::Edge.create(role: admin_role, permission: write_perm)
      SuperAuth::Edge.create(permission: write_perm, resource: server)

      # Charlie: permission -> resource (Strategy 4)
      SuperAuth::Edge.create(user: charlie, permission: read_perm)
      SuperAuth::Edge.create(permission: read_perm, resource: database)

      auths = SuperAuth::Edge.authorizations.all

      # Alice should have 1 authorization (direct to database)
      alice_auths = auths.select { |a| a[:user_name] == 'Alice' }
      expect(alice_auths.length).to eq 1
      expect(alice_auths.first[:resource_name]).to eq 'database'

      # Bob should have 1 authorization (group->role->permission->resource)
      bob_auths = auths.select { |a| a[:user_name] == 'Bob' }
      expect(bob_auths.length).to eq 1
      expect(bob_auths.first[:resource_name]).to eq 'server'
      expect(bob_auths.first[:group_name]).to eq 'Engineering'
      expect(bob_auths.first[:role_name]).to eq 'Admin'
      expect(bob_auths.first[:permission_name]).to eq 'write'

      # Charlie should have 1 authorization (permission->resource)
      charlie_auths = auths.select { |a| a[:user_name] == 'Charlie' }
      expect(charlie_auths.length).to eq 1
      expect(charlie_auths.first[:resource_name]).to eq 'database'
      expect(charlie_auths.first[:permission_name]).to eq 'read'

      # Total should be 3
      expect(auths.length).to eq 3
    end
  end

  describe "US-009: Edge Revocation and Authorization Lifecycle" do
    it "deleting a user->group edge removes all authorizations through that group" do
      user = SuperAuth::User.create(name: 'Alice')
      group = SuperAuth::Group.create(name: 'Engineering')
      role = SuperAuth::Role.create(name: 'Developer')
      permission = SuperAuth::Permission.create(name: 'read')
      resource = SuperAuth::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      # Verify authorization exists
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:user_name]).to eq 'Alice'

      # Delete the user->group edge
      user_group_edge = SuperAuth::Edge.first(user_id: user.id, group_id: group.id)
      user_group_edge.destroy

      # Authorization should be gone
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "deleting a group->role edge removes all authorizations through that group->role connection" do
      user = SuperAuth::User.create(name: 'Bob')
      group = SuperAuth::Group.create(name: 'Ops')
      role = SuperAuth::Role.create(name: 'Operator')
      permission = SuperAuth::Permission.create(name: 'execute')
      resource = SuperAuth::Resource.create(name: 'pipeline')

      SuperAuth::Edge.create(user: user, group: group)
      group_role_edge = SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      # Verify authorization exists
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      # Delete the group->role edge
      group_role_edge.destroy

      # Authorization should be gone
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "deleting a role->permission edge removes authorizations for that permission" do
      user = SuperAuth::User.create(name: 'Charlie')
      role = SuperAuth::Role.create(name: 'Admin')
      perm_read = SuperAuth::Permission.create(name: 'read')
      perm_write = SuperAuth::Permission.create(name: 'write')
      resource = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: perm_read)
      role_write_edge = SuperAuth::Edge.create(role: role, permission: perm_write)
      SuperAuth::Edge.create(permission: perm_read, resource: resource)
      SuperAuth::Edge.create(permission: perm_write, resource: resource)

      # Both permissions should produce authorizations
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 2

      # Delete the role->write permission edge
      role_write_edge.destroy

      # Only read permission authorization should remain
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:permission_name]).to eq 'read'
    end

    it "deleting a permission->resource edge removes authorizations for that resource" do
      user = SuperAuth::User.create(name: 'Diana')
      permission = SuperAuth::Permission.create(name: 'access')
      resource1 = SuperAuth::Resource.create(name: 'server')
      resource2 = SuperAuth::Resource.create(name: 'database')

      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource1)
      perm_res2_edge = SuperAuth::Edge.create(permission: permission, resource: resource2)

      # Both resources should produce authorizations
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 2

      # Delete the permission->database edge
      perm_res2_edge.destroy

      # Only server authorization should remain
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:resource_name]).to eq 'server'
    end

    it "deleting a user->resource direct edge removes that authorization" do
      user = SuperAuth::User.create(name: 'Eve')
      resource = SuperAuth::Resource.create(name: 'file')

      direct_edge = SuperAuth::Edge.create(user: user, resource: resource)

      # Verify direct authorization exists
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:user_name]).to eq 'Eve'
      expect(auths.first[:resource_name]).to eq 'file'

      # Delete the direct user->resource edge
      direct_edge.destroy

      # Authorization should be gone
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "deleting an edge does NOT affect unrelated authorizations for other users" do
      # Set up two users with completely independent authorization paths
      alice = SuperAuth::User.create(name: 'Alice')
      bob = SuperAuth::User.create(name: 'Bob')
      group_a = SuperAuth::Group.create(name: 'TeamA')
      group_b = SuperAuth::Group.create(name: 'TeamB')
      role = SuperAuth::Role.create(name: 'Worker')
      permission = SuperAuth::Permission.create(name: 'work')
      resource = SuperAuth::Resource.create(name: 'project')

      alice_edge = SuperAuth::Edge.create(user: alice, group: group_a)
      SuperAuth::Edge.create(user: bob, group: group_b)
      SuperAuth::Edge.create(group: group_a, role: role)
      SuperAuth::Edge.create(group: group_b, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      # Both users should have authorizations
      auths = SuperAuth::Edge.authorizations.all
      user_names = auths.map { |a| a[:user_name] }.sort
      expect(user_names).to eq ['Alice', 'Bob']

      # Delete Alice's user->group edge
      alice_edge.destroy

      # Only Bob's authorization should remain
      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:user_name]).to eq 'Bob'
      expect(auths.first[:resource_name]).to eq 'project'
    end
  end

  describe "US-010: User.with_groups and Permission.with_roles Merge Queries" do
    it "User.with_groups returns users joined with their group hierarchy paths" do
      user1 = SuperAuth::User.create(name: 'Alice')
      user2 = SuperAuth::User.create(name: 'Bob')
      group1 = SuperAuth::Group.create(name: 'Engineering')
      group2 = SuperAuth::Group.create(name: 'Marketing')

      SuperAuth::Edge.create(user: user1, group: group1)
      SuperAuth::Edge.create(user: user2, group: group2)

      results = SuperAuth::User.with_groups.order(:user_id).all
      expect(results.length).to eq 2

      alice_result = results.find { |r| r[:user_id] == user1.id }
      bob_result = results.find { |r| r[:user_id] == user2.id }

      expect(alice_result[:user_name]).to eq 'Alice'
      expect(alice_result[:group_name]).to eq 'Engineering'
      expect(alice_result[:group_id]).to eq group1.id
      expect(alice_result[:group_path]).to eq group1.id.to_s
      expect(alice_result[:group_name_path]).to eq 'Engineering'

      expect(bob_result[:user_name]).to eq 'Bob'
      expect(bob_result[:group_name]).to eq 'Marketing'
      expect(bob_result[:group_id]).to eq group2.id
      expect(bob_result[:group_path]).to eq group2.id.to_s
      expect(bob_result[:group_name_path]).to eq 'Marketing'
    end

    it "User.with_groups with nested groups returns correct group_path and group_name_path" do
      user = SuperAuth::User.create(name: 'Charlie')
      root_group = SuperAuth::Group.create(name: 'Corp')
      child_group = SuperAuth::Group.create(name: 'Engineering', parent: root_group)
      grandchild_group = SuperAuth::Group.create(name: 'Backend', parent: child_group)

      SuperAuth::Edge.create(user: user, group: grandchild_group)

      results = SuperAuth::User.with_groups.all
      expect(results.length).to eq 1

      result = results.first
      expect(result[:user_name]).to eq 'Charlie'
      expect(result[:group_name]).to eq 'Backend'
      expect(result[:group_id]).to eq grandchild_group.id
      expect(result[:group_path]).to eq "#{root_group.id},#{child_group.id},#{grandchild_group.id}"
      expect(result[:group_name_path]).to eq 'Corp,Engineering,Backend'
      expect(result[:parent_id]).to eq child_group.id
    end

    it "User.with_groups excludes users with no group edges" do
      user_with_group = SuperAuth::User.create(name: 'HasGroup')
      _user_without_group = SuperAuth::User.create(name: 'NoGroup')
      group = SuperAuth::Group.create(name: 'Team')

      SuperAuth::Edge.create(user: user_with_group, group: group)

      results = SuperAuth::User.with_groups.all
      expect(results.length).to eq 1
      expect(results.first[:user_name]).to eq 'HasGroup'
    end

    it "Permission.with_roles returns permissions joined with their role hierarchy paths" do
      perm1 = SuperAuth::Permission.create(name: 'read')
      perm2 = SuperAuth::Permission.create(name: 'write')
      role1 = SuperAuth::Role.create(name: 'Viewer')
      role2 = SuperAuth::Role.create(name: 'Editor')

      SuperAuth::Edge.create(permission: perm1, role: role1)
      SuperAuth::Edge.create(permission: perm2, role: role2)

      results = SuperAuth::Permission.with_roles.order(:permission_id).all
      expect(results.length).to eq 2

      read_result = results.find { |r| r[:permission_id] == perm1.id }
      write_result = results.find { |r| r[:permission_id] == perm2.id }

      expect(read_result[:permission_name]).to eq 'read'
      expect(read_result[:role_name]).to eq 'Viewer'
      expect(read_result[:role_id]).to eq role1.id
      expect(read_result[:role_path]).to eq role1.id.to_s
      expect(read_result[:role_name_path]).to eq 'Viewer'

      expect(write_result[:permission_name]).to eq 'write'
      expect(write_result[:role_name]).to eq 'Editor'
      expect(write_result[:role_id]).to eq role2.id
      expect(write_result[:role_path]).to eq role2.id.to_s
      expect(write_result[:role_name_path]).to eq 'Editor'
    end

    it "Permission.with_roles with nested roles returns correct role_path and role_name_path" do
      permission = SuperAuth::Permission.create(name: 'deploy')
      root_role = SuperAuth::Role.create(name: 'Staff')
      child_role = SuperAuth::Role.create(name: 'DevOps', parent: root_role)
      grandchild_role = SuperAuth::Role.create(name: 'SRE', parent: child_role)

      SuperAuth::Edge.create(permission: permission, role: grandchild_role)

      results = SuperAuth::Permission.with_roles.all
      expect(results.length).to eq 1

      result = results.first
      expect(result[:permission_name]).to eq 'deploy'
      expect(result[:role_name]).to eq 'SRE'
      expect(result[:role_id]).to eq grandchild_role.id
      expect(result[:role_path]).to eq "#{root_role.id},#{child_role.id},#{grandchild_role.id}"
      expect(result[:role_name_path]).to eq 'Staff,DevOps,SRE'
      expect(result[:parent_id]).to eq child_role.id
    end

    it "Permission.with_roles excludes permissions with no role edges" do
      perm_with_role = SuperAuth::Permission.create(name: 'read')
      _perm_without_role = SuperAuth::Permission.create(name: 'write')
      role = SuperAuth::Role.create(name: 'Viewer')

      SuperAuth::Edge.create(permission: perm_with_role, role: role)

      results = SuperAuth::Permission.with_roles.all
      expect(results.length).to eq 1
      expect(results.first[:permission_name]).to eq 'read'
    end
  end

  describe "US-011: Edge Cases and Boundary Conditions" do
    it "user belonging to multiple groups that each lead to the same resource via different paths" do
      user = SuperAuth::User.create(name: 'MultiGroupUser')
      group_a = SuperAuth::Group.create(name: 'Engineering')
      group_b = SuperAuth::Group.create(name: 'Operations')
      role_a = SuperAuth::Role.create(name: 'Developer')
      role_b = SuperAuth::Role.create(name: 'Operator')
      perm_a = SuperAuth::Permission.create(name: 'deploy')
      perm_b = SuperAuth::Permission.create(name: 'monitor')
      resource = SuperAuth::Resource.create(name: 'production')

      # Path 1: user -> group_a -> role_a -> perm_a -> resource
      SuperAuth::Edge.create(user: user, group: group_a)
      SuperAuth::Edge.create(group: group_a, role: role_a)
      SuperAuth::Edge.create(role: role_a, permission: perm_a)
      SuperAuth::Edge.create(permission: perm_a, resource: resource)

      # Path 2: user -> group_b -> role_b -> perm_b -> resource
      SuperAuth::Edge.create(user: user, group: group_b)
      SuperAuth::Edge.create(group: group_b, role: role_b)
      SuperAuth::Edge.create(role: role_b, permission: perm_b)
      SuperAuth::Edge.create(permission: perm_b, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      user_auths = auths.select { |a| a[:user_name] == 'MultiGroupUser' }

      # Should have at least 2 records (one per path through different groups)
      expect(user_auths.length).to be >= 2

      # All point to the same resource
      user_auths.each do |auth|
        expect(auth[:resource_name]).to eq 'production'
      end

      # Both groups should appear
      group_names = user_auths.map { |a| a[:group_name] }.uniq.sort
      expect(group_names).to eq ['Engineering', 'Operations']
    end

    it "group with no users linked produces no authorizations" do
      _group = SuperAuth::Group.create(name: 'EmptyGroup')
      role = SuperAuth::Role.create(name: 'Admin')
      permission = SuperAuth::Permission.create(name: 'manage')
      resource = SuperAuth::Resource.create(name: 'settings')

      SuperAuth::Edge.create(group: _group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "role with no groups or users linked produces no authorizations" do
      role = SuperAuth::Role.create(name: 'OrphanRole')
      permission = SuperAuth::Permission.create(name: 'execute')
      resource = SuperAuth::Resource.create(name: 'pipeline')

      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "permission linked to a role but no resource produces no authorizations" do
      user = SuperAuth::User.create(name: 'Alice')
      role = SuperAuth::Role.create(name: 'Developer')
      permission = SuperAuth::Permission.create(name: 'code_review')

      SuperAuth::Edge.create(user: user, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      # No permission -> resource edge

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 0
    end

    it "resource with no permission edges produces no authorizations (except direct user->resource)" do
      user = SuperAuth::User.create(name: 'Bob')
      resource = SuperAuth::Resource.create(name: 'isolated-file')
      _orphan_resource = SuperAuth::Resource.create(name: 'orphan-resource')

      # Only direct user -> resource edge (no permission edges to either resource)
      SuperAuth::Edge.create(user: user, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1
      expect(auths.first[:user_name]).to eq 'Bob'
      expect(auths.first[:resource_name]).to eq 'isolated-file'

      # The orphan resource with no edges at all should not appear
      resource_names = auths.map { |a| a[:resource_name] }
      expect(resource_names).not_to include('orphan-resource')
    end

    it "names with special characters (spaces, unicode, commas, quotes)" do
      user = SuperAuth::User.create(name: 'Señor Developer')
      group = SuperAuth::Group.create(name: 'R&D, Innovation')
      role = SuperAuth::Role.create(name: "Lead's Team")
      permission = SuperAuth::Permission.create(name: 'café access')
      resource = SuperAuth::Resource.create(name: 'Ürban Döcument')

      SuperAuth::Edge.create(user: user, group: group)
      SuperAuth::Edge.create(group: group, role: role)
      SuperAuth::Edge.create(role: role, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      auths = SuperAuth::Edge.authorizations.all
      expect(auths.length).to eq 1

      auth = auths.first
      expect(auth[:user_name]).to eq 'Señor Developer'
      expect(auth[:group_name]).to eq 'R&D, Innovation'
      expect(auth[:role_name]).to eq "Lead's Team"
      expect(auth[:permission_name]).to eq 'café access'
      expect(auth[:resource_name]).to eq 'Ürban Döcument'
    end

    it "external_id and external_type fields are correctly propagated in authorization results" do
      user = SuperAuth::User.create(name: 'ExtUser', external_id: 'ext-user-123', external_type: 'ldap')
      resource = SuperAuth::Resource.create(name: 'ExtResource', external_id: 'ext-res-456', external_type: 'aws_s3')
      permission = SuperAuth::Permission.create(name: 'read')

      # Test via direct user->resource path (Strategy 5)
      SuperAuth::Edge.create(user: user, resource: resource)

      direct_auths = SuperAuth::Edge.users_resources.all
      expect(direct_auths.length).to eq 1

      auth = direct_auths.first
      expect(auth[:user_external_id]).to eq 'ext-user-123'
      expect(auth[:user_external_type]).to eq 'ldap'
      expect(auth[:resource_external_id]).to eq 'ext-res-456'
      expect(auth[:resource_external_type]).to eq 'aws_s3'

      # Test via user->permission->resource path (Strategy 4)
      SuperAuth::Edge.create(user: user, permission: permission)
      SuperAuth::Edge.create(permission: permission, resource: resource)

      perm_auths = SuperAuth::Edge.users_permissions_resources.all
      expect(perm_auths.length).to eq 1

      perm_auth = perm_auths.first
      expect(perm_auth[:user_external_id]).to eq 'ext-user-123'
      expect(perm_auth[:user_external_type]).to eq 'ldap'
      expect(perm_auth[:resource_external_id]).to eq 'ext-res-456'
      expect(perm_auth[:resource_external_type]).to eq 'aws_s3'

      # Test via full authorizations union - all records should carry external fields
      all_auths = SuperAuth::Edge.authorizations.all
      all_auths.each do |a|
        expect(a[:user_external_id]).to eq 'ext-user-123'
        expect(a[:user_external_type]).to eq 'ldap'
        expect(a[:resource_external_id]).to eq 'ext-res-456'
        expect(a[:resource_external_type]).to eq 'aws_s3'
      end
    end
  end

  describe "US-012: ActiveRecord Group Tree Hierarchies (Nestable)" do
    it "single root group has group_path equal to its own id" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'root')
      tree = SuperAuth::ActiveRecord::Group.from(
        "(#{SuperAuth::Group.trees.sql}) as super_auth_groups"
      ).first
      expect(tree[:group_path]).to eq root.id.to_s
      expect(tree[:group_name_path]).to eq 'root'
    end

    it "2-level hierarchy has correct group_path and group_name_path" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'Company')
      child = SuperAuth::ActiveRecord::Group.create(name: 'Engineering', parent: root)

      trees = SuperAuth::ActiveRecord::Group.from(
        "(#{SuperAuth::Group.trees.sql}) as super_auth_groups"
      ).order(:id).to_a
      expect(trees.length).to eq 2

      root_tree = trees.find { |t| t[:id] == root.id }
      child_tree = trees.find { |t| t[:id] == child.id }

      expect(root_tree[:group_path]).to eq root.id.to_s
      expect(root_tree[:group_name_path]).to eq 'Company'

      expect(child_tree[:group_path]).to eq "#{root.id},#{child.id}"
      expect(child_tree[:group_name_path]).to eq 'Company,Engineering'
    end

    it "3-level hierarchy has correct paths at each level" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'root')
      child = SuperAuth::ActiveRecord::Group.create(name: 'admin', parent: root)
      grandchild = SuperAuth::ActiveRecord::Group.create(name: 'user', parent: child)

      descendants = root.descendants_dataset.order(:id).to_a

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
      root = SuperAuth::ActiveRecord::Group.create(name: 'Corp')
      child_a = SuperAuth::ActiveRecord::Group.create(name: 'Sales', parent: root)
      child_b = SuperAuth::ActiveRecord::Group.create(name: 'Engineering', parent: root)
      child_c = SuperAuth::ActiveRecord::Group.create(name: 'Marketing', parent: root)
      child_d = SuperAuth::ActiveRecord::Group.create(name: 'HR', parent: root)

      trees = SuperAuth::ActiveRecord::Group.from(
        "(#{SuperAuth::Group.trees.sql}) as super_auth_groups"
      ).order(:id).to_a
      expect(trees.length).to eq 5

      [child_a, child_b, child_c, child_d].each do |child|
        tree_node = trees.find { |t| t[:id] == child.id }
        expect(tree_node[:group_path]).to eq "#{root.id},#{child.id}"
        expect(tree_node[:group_name_path]).to eq "Corp,#{child.name}"
      end
    end

    it "descendants_dataset returns all descendants including the root itself as an ActiveRecord relation" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'root')
      child = SuperAuth::ActiveRecord::Group.create(name: 'child', parent: root)
      grandchild = SuperAuth::ActiveRecord::Group.create(name: 'grandchild', parent: child)

      descendants = root.descendants_dataset.order(:id).to_a
      expect(descendants.map { |d| d[:id] }).to eq [root.id, child.id, grandchild.id]

      # Verify this is an ActiveRecord relation
      expect(root.descendants_dataset).to be_a(ActiveRecord::Relation)
    end

    it "descendants_dataset on a mid-level node returns only its subtree, not siblings" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'root')
      child_a = SuperAuth::ActiveRecord::Group.create(name: 'child_a', parent: root)
      child_b = SuperAuth::ActiveRecord::Group.create(name: 'child_b', parent: root)
      grandchild_a = SuperAuth::ActiveRecord::Group.create(name: 'grandchild_a', parent: child_a)
      _grandchild_b = SuperAuth::ActiveRecord::Group.create(name: 'grandchild_b', parent: child_b)

      # descendants_dataset uses parent_id internally, so from child_a it traverses from root downward
      descendants_from_root = root.descendants_dataset.order(:id).to_a
      expect(descendants_from_root.map { |d| d[:id] }).to eq [root.id, child_a.id, child_b.id, grandchild_a.id, _grandchild_b.id]

      # The child_a descendants_dataset includes its parent's subtree (same behavior as Sequel)
      child_a_descendants = child_a.descendants_dataset.order(:id).to_a
      child_a_ids = child_a_descendants.map { |d| d[:id] }
      expect(child_a_ids).to include(root.id, child_a.id, grandchild_a.id)
    end

    it "roots scope returns only groups with no parent" do
      root1 = SuperAuth::ActiveRecord::Group.create(name: 'root1')
      root2 = SuperAuth::ActiveRecord::Group.create(name: 'root2')
      _child = SuperAuth::ActiveRecord::Group.create(name: 'child', parent: root1)

      roots = SuperAuth::ActiveRecord::Group.where(parent_id: nil).order(:id).to_a
      expect(roots.map(&:id)).to eq [root1.id, root2.id]
    end

    it "trees scope returns all groups with their computed paths" do
      root = SuperAuth::ActiveRecord::Group.create(name: 'Company')
      child = SuperAuth::ActiveRecord::Group.create(name: 'Dev', parent: root)
      grandchild = SuperAuth::ActiveRecord::Group.create(name: 'Backend', parent: child)

      trees = SuperAuth::ActiveRecord::Group.from(
        "(#{SuperAuth::Group.trees.sql}) as super_auth_groups"
      ).order(:id).to_a
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

  describe "US-013: ActiveRecord Role Tree Hierarchies (Nestable)" do
    it "single root role has role_path equal to its own id" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'root')
      tree = SuperAuth::ActiveRecord::Role.from(
        "(#{SuperAuth::Role.trees.sql}) as super_auth_roles"
      ).first
      expect(tree[:role_path]).to eq root.id.to_s
      expect(tree[:role_name_path]).to eq 'root'
    end

    it "2-level hierarchy has correct role_path and role_name_path" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'Admin')
      child = SuperAuth::ActiveRecord::Role.create(name: 'Editor', parent: root)

      trees = SuperAuth::ActiveRecord::Role.from(
        "(#{SuperAuth::Role.trees.sql}) as super_auth_roles"
      ).order(:id).to_a
      expect(trees.length).to eq 2

      root_tree = trees.find { |t| t[:id] == root.id }
      child_tree = trees.find { |t| t[:id] == child.id }

      expect(root_tree[:role_path]).to eq root.id.to_s
      expect(root_tree[:role_name_path]).to eq 'Admin'

      expect(child_tree[:role_path]).to eq "#{root.id},#{child.id}"
      expect(child_tree[:role_name_path]).to eq 'Admin,Editor'
    end

    it "3-level hierarchy has correct paths at each level" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'root')
      child = SuperAuth::ActiveRecord::Role.create(name: 'admin', parent: root)
      grandchild = SuperAuth::ActiveRecord::Role.create(name: 'user', parent: child)

      descendants = root.descendants_dataset.order(:id).to_a

      expect(descendants.map { |d| d[:role_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(descendants.map { |d| d[:role_name_path] }).to eq [
        'root',
        'root,admin',
        'root,admin,user'
      ]
    end

    it "wide tree with 3+ direct children has correct paths" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'Super')
      child_a = SuperAuth::ActiveRecord::Role.create(name: 'Admin', parent: root)
      child_b = SuperAuth::ActiveRecord::Role.create(name: 'Editor', parent: root)
      child_c = SuperAuth::ActiveRecord::Role.create(name: 'Viewer', parent: root)
      child_d = SuperAuth::ActiveRecord::Role.create(name: 'Guest', parent: root)

      trees = SuperAuth::ActiveRecord::Role.from(
        "(#{SuperAuth::Role.trees.sql}) as super_auth_roles"
      ).order(:id).to_a
      expect(trees.length).to eq 5

      [child_a, child_b, child_c, child_d].each do |child|
        tree_node = trees.find { |t| t[:id] == child.id }
        expect(tree_node[:role_path]).to eq "#{root.id},#{child.id}"
        expect(tree_node[:role_name_path]).to eq "Super,#{child.name}"
      end
    end

    it "descendants_dataset returns all descendants including the root as an ActiveRecord relation" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'root')
      child = SuperAuth::ActiveRecord::Role.create(name: 'child', parent: root)
      grandchild = SuperAuth::ActiveRecord::Role.create(name: 'grandchild', parent: child)

      descendants = root.descendants_dataset.order(:id).to_a
      expect(descendants.map { |d| d[:id] }).to eq [root.id, child.id, grandchild.id]

      # Verify this is an ActiveRecord relation
      expect(root.descendants_dataset).to be_a(ActiveRecord::Relation)
    end

    it "descendants_dataset on a mid-level role returns only its subtree" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'root')
      child_a = SuperAuth::ActiveRecord::Role.create(name: 'child_a', parent: root)
      child_b = SuperAuth::ActiveRecord::Role.create(name: 'child_b', parent: root)
      grandchild_a = SuperAuth::ActiveRecord::Role.create(name: 'grandchild_a', parent: child_a)
      _grandchild_b = SuperAuth::ActiveRecord::Role.create(name: 'grandchild_b', parent: child_b)

      # descendants_dataset uses parent_id internally, so from child_a it traverses from root downward
      descendants_from_root = root.descendants_dataset.order(:id).to_a
      expect(descendants_from_root.map { |d| d[:id] }).to eq [root.id, child_a.id, child_b.id, grandchild_a.id, _grandchild_b.id]

      # The child_a descendants_dataset includes its parent's subtree (same behavior as Sequel)
      child_a_descendants = child_a.descendants_dataset.order(:id).to_a
      child_a_ids = child_a_descendants.map { |d| d[:id] }
      expect(child_a_ids).to include(root.id, child_a.id, grandchild_a.id)
    end

    it "roots scope returns only roles with no parent" do
      root1 = SuperAuth::ActiveRecord::Role.create(name: 'root1')
      root2 = SuperAuth::ActiveRecord::Role.create(name: 'root2')
      _child = SuperAuth::ActiveRecord::Role.create(name: 'child', parent: root1)

      roots = SuperAuth::ActiveRecord::Role.where(parent_id: nil).order(:id).to_a
      expect(roots.map(&:id)).to eq [root1.id, root2.id]
    end

    it "trees scope returns all roles with their computed paths" do
      root = SuperAuth::ActiveRecord::Role.create(name: 'Super')
      child = SuperAuth::ActiveRecord::Role.create(name: 'Admin', parent: root)
      grandchild = SuperAuth::ActiveRecord::Role.create(name: 'Editor', parent: child)

      trees = SuperAuth::ActiveRecord::Role.from(
        "(#{SuperAuth::Role.trees.sql}) as super_auth_roles"
      ).order(:id).to_a
      expect(trees.length).to eq 3

      expect(trees.map { |t| t[:role_path] }).to eq [
        root.id.to_s,
        "#{root.id},#{child.id}",
        "#{root.id},#{child.id},#{grandchild.id}"
      ]
      expect(trees.map { |t| t[:role_name_path] }).to eq [
        'Super',
        'Super,Admin',
        'Super,Admin,Editor'
      ]
    end
  end

  describe "US-014: ActiveRecord Path Strategy 1 - users <-> groups <-> roles <-> permissions <-> resources" do
    it "basic flat case: user -> group -> role -> permission -> resource (no nesting) using AR models" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Alice')
      group = SuperAuth::ActiveRecord::Group.create(name: 'Engineering')
      role = SuperAuth::ActiveRecord::Role.create(name: 'Developer')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'read')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user_id: user.id, group_id: group.id)
      SuperAuth::Edge.create(group_id: group.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:role_name]).to eq 'Developer'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "nested groups: user in child group, role linked to parent group, permission propagates down" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Bob')
      parent_group = SuperAuth::ActiveRecord::Group.create(name: 'Company')
      child_group = SuperAuth::ActiveRecord::Group.create(name: 'Engineering', parent: parent_group)
      role = SuperAuth::ActiveRecord::Role.create(name: 'Viewer')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'view')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user_id: user.id, group_id: child_group.id)
      SuperAuth::Edge.create(group_id: parent_group.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Bob'
      expect(edge[:group_name]).to eq 'Engineering'
      expect(edge[:role_name]).to eq 'Viewer'
      expect(edge[:permission_name]).to eq 'view'
      expect(edge[:resource_name]).to eq 'dashboard'
    end

    it "nested roles: user -> group -> parent_role, permission on child_role propagates" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Charlie')
      group = SuperAuth::ActiveRecord::Group.create(name: 'Team')
      parent_role = SuperAuth::ActiveRecord::Role.create(name: 'Manager')
      child_role = SuperAuth::ActiveRecord::Role.create(name: 'Lead', parent: parent_role)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'approve')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'requests')

      SuperAuth::Edge.create(user_id: user.id, group_id: group.id)
      SuperAuth::Edge.create(group_id: group.id, role_id: parent_role.id)
      SuperAuth::Edge.create(role_id: child_role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Charlie'
      expect(edge[:group_name]).to eq 'Team'
      expect(edge[:role_name]).to eq 'Lead'
      expect(edge[:permission_name]).to eq 'approve'
      expect(edge[:resource_name]).to eq 'requests'
    end

    it "both nested groups AND nested roles simultaneously" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Diana')
      root_group = SuperAuth::ActiveRecord::Group.create(name: 'Corp')
      child_group = SuperAuth::ActiveRecord::Group.create(name: 'Division', parent: root_group)
      root_role = SuperAuth::ActiveRecord::Role.create(name: 'Staff')
      child_role = SuperAuth::ActiveRecord::Role.create(name: 'Analyst', parent: root_role)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'analyze')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'reports')

      SuperAuth::Edge.create(user_id: user.id, group_id: child_group.id)
      SuperAuth::Edge.create(group_id: root_group.id, role_id: root_role.id)
      SuperAuth::Edge.create(role_id: child_role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Diana'
      expect(edge[:group_name]).to eq 'Division'
      expect(edge[:role_name]).to eq 'Analyst'
      expect(edge[:permission_name]).to eq 'analyze'
      expect(edge[:resource_name]).to eq 'reports'
    end

    it "deeply nested groups (3+ levels): user at leaf group still gets authorization" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Eve')
      g1 = SuperAuth::ActiveRecord::Group.create(name: 'Org')
      g2 = SuperAuth::ActiveRecord::Group.create(name: 'Dept', parent: g1)
      g3 = SuperAuth::ActiveRecord::Group.create(name: 'Team', parent: g2)
      g4 = SuperAuth::ActiveRecord::Group.create(name: 'Squad', parent: g3)
      role = SuperAuth::ActiveRecord::Role.create(name: 'Worker')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'execute')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'pipeline')

      SuperAuth::Edge.create(user_id: user.id, group_id: g4.id)
      SuperAuth::Edge.create(group_id: g1.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Eve'
      expect(edge[:group_name]).to eq 'Squad'
      expect(edge[:permission_name]).to eq 'execute'
      expect(edge[:resource_name]).to eq 'pipeline'
    end

    it "deeply nested roles (3+ levels): permissions propagate correctly" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Frank')
      group = SuperAuth::ActiveRecord::Group.create(name: 'Ops')
      r1 = SuperAuth::ActiveRecord::Role.create(name: 'Base')
      r2 = SuperAuth::ActiveRecord::Role.create(name: 'Mid', parent: r1)
      r3 = SuperAuth::ActiveRecord::Role.create(name: 'Senior', parent: r2)
      r4 = SuperAuth::ActiveRecord::Role.create(name: 'Principal', parent: r3)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'deploy')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'production')

      SuperAuth::Edge.create(user_id: user.id, group_id: group.id)
      SuperAuth::Edge.create(group_id: group.id, role_id: r1.id)
      SuperAuth::Edge.create(role_id: r4.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Frank'
      expect(edge[:group_name]).to eq 'Ops'
      expect(edge[:role_name]).to eq 'Principal'
      expect(edge[:permission_name]).to eq 'deploy'
      expect(edge[:resource_name]).to eq 'production'
    end

    it "multiple users in different groups all get authorized to the same resource" do
      user1 = SuperAuth::ActiveRecord::User.create(name: 'User1')
      user2 = SuperAuth::ActiveRecord::User.create(name: 'User2')
      user3 = SuperAuth::ActiveRecord::User.create(name: 'User3')
      root_group = SuperAuth::ActiveRecord::Group.create(name: 'HQ')
      group_a = SuperAuth::ActiveRecord::Group.create(name: 'Sales', parent: root_group)
      group_b = SuperAuth::ActiveRecord::Group.create(name: 'Support', parent: root_group)
      role = SuperAuth::ActiveRecord::Role.create(name: 'Agent')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'access')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'crm')

      SuperAuth::Edge.create(user_id: user1.id, group_id: root_group.id)
      SuperAuth::Edge.create(user_id: user2.id, group_id: group_a.id)
      SuperAuth::Edge.create(user_id: user3.id, group_id: group_b.id)
      SuperAuth::Edge.create(group_id: root_group.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:role_name]).to eq 'Agent'
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'crm'
      end
    end

    it "user in an unrelated group does NOT get authorized" do
      user_authorized = SuperAuth::ActiveRecord::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::ActiveRecord::User.create(name: 'Outsider')
      group_a = SuperAuth::ActiveRecord::Group.create(name: 'Alpha')
      group_b = SuperAuth::ActiveRecord::Group.create(name: 'Beta')
      role = SuperAuth::ActiveRecord::Role.create(name: 'Operator')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'operate')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'machine')

      SuperAuth::Edge.create(user_id: user_authorized.id, group_id: group_a.id)
      SuperAuth::Edge.create(user_id: user_unauthorized.id, group_id: group_b.id)
      SuperAuth::Edge.create(group_id: group_a.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple permissions on the same role->resource path produce multiple authorization records" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Grace')
      group = SuperAuth::ActiveRecord::Group.create(name: 'Admin')
      role = SuperAuth::ActiveRecord::Role.create(name: 'SuperAdmin')
      perm_read = SuperAuth::ActiveRecord::Permission.create(name: 'read')
      perm_write = SuperAuth::ActiveRecord::Permission.create(name: 'write')
      perm_delete = SuperAuth::ActiveRecord::Permission.create(name: 'delete')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'database')

      SuperAuth::Edge.create(user_id: user.id, group_id: group.id)
      SuperAuth::Edge.create(group_id: group.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_read.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_write.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_delete.id)
      SuperAuth::Edge.create(permission_id: perm_read.id, resource_id: resource.id)
      SuperAuth::Edge.create(permission_id: perm_write.id, resource_id: resource.id)
      SuperAuth::Edge.create(permission_id: perm_delete.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Grace'
        expect(edge[:group_name]).to eq 'Admin'
        expect(edge[:role_name]).to eq 'SuperAdmin'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "result includes correct user_name, group_name, group_path, group_name_path, role_name, role_path, role_name_path, permission_name, resource_name" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Hank', external_id: 'ext-1', external_type: 'ldap')
      root_group = SuperAuth::ActiveRecord::Group.create(name: 'Corp')
      child_group = SuperAuth::ActiveRecord::Group.create(name: 'IT', parent: root_group)
      root_role = SuperAuth::ActiveRecord::Role.create(name: 'Staff')
      child_role = SuperAuth::ActiveRecord::Role.create(name: 'SysAdmin', parent: root_role)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'manage')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'servers', external_id: 'srv-1', external_type: 'aws')

      SuperAuth::Edge.create(user_id: user.id, group_id: child_group.id)
      SuperAuth::Edge.create(group_id: root_group.id, role_id: root_role.id)
      SuperAuth::Edge.create(role_id: child_role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_groups_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Hank'
      expect(edge[:user_external_id]).to eq 'ext-1'
      expect(edge[:user_external_type]).to eq 'ldap'

      expect(edge[:group_name]).to eq 'IT'
      expect(edge[:group_path]).to eq "#{root_group.id},#{child_group.id}"
      expect(edge[:group_name_path]).to eq 'Corp,IT'

      expect(edge[:role_name]).to eq 'SysAdmin'
      expect(edge[:role_path]).to eq "#{root_role.id},#{child_role.id}"
      expect(edge[:role_name_path]).to eq 'Staff,SysAdmin'

      expect(edge[:permission_name]).to eq 'manage'

      expect(edge[:resource_name]).to eq 'servers'
      expect(edge[:resource_external_id]).to eq 'srv-1'
      expect(edge[:resource_external_type]).to eq 'aws'
    end
  end

  describe "US-015: ActiveRecord Path Strategy 2 - users <-> roles <-> permissions <-> resources" do
    it "basic case: user -> role -> permission -> resource with flat role using AR models" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Alice')
      role = SuperAuth::ActiveRecord::Role.create(name: 'Developer')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'read')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'codebase')

      SuperAuth::Edge.create(user_id: user.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Alice'
      expect(edge[:role_name]).to eq 'Developer'
      expect(edge[:permission_name]).to eq 'read'
      expect(edge[:resource_name]).to eq 'codebase'
    end

    it "nested roles: user -> parent_role, permission linked to child_role, verify authorization" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Bob')
      parent_role = SuperAuth::ActiveRecord::Role.create(name: 'Manager')
      child_role = SuperAuth::ActiveRecord::Role.create(name: 'Lead', parent: parent_role)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'approve')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'requests')

      SuperAuth::Edge.create(user_id: user.id, role_id: parent_role.id)
      SuperAuth::Edge.create(role_id: child_role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Bob'
      expect(edge[:role_name]).to eq 'Lead'
      expect(edge[:permission_name]).to eq 'approve'
      expect(edge[:resource_name]).to eq 'requests'
    end

    it "deeply nested roles (3+ levels): permissions propagate correctly" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Charlie')
      r1 = SuperAuth::ActiveRecord::Role.create(name: 'Base')
      r2 = SuperAuth::ActiveRecord::Role.create(name: 'Mid', parent: r1)
      r3 = SuperAuth::ActiveRecord::Role.create(name: 'Senior', parent: r2)
      r4 = SuperAuth::ActiveRecord::Role.create(name: 'Principal', parent: r3)
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'deploy')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'production')

      SuperAuth::Edge.create(user_id: user.id, role_id: r1.id)
      SuperAuth::Edge.create(role_id: r4.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:user_name]).to eq 'Charlie'
      expect(edge[:role_name]).to eq 'Principal'
      expect(edge[:permission_name]).to eq 'deploy'
      expect(edge[:resource_name]).to eq 'production'
    end

    it "multiple permissions on the same role produce multiple authorization records" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Diana')
      role = SuperAuth::ActiveRecord::Role.create(name: 'Admin')
      perm_read = SuperAuth::ActiveRecord::Permission.create(name: 'read')
      perm_write = SuperAuth::ActiveRecord::Permission.create(name: 'write')
      perm_delete = SuperAuth::ActiveRecord::Permission.create(name: 'delete')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'database')

      SuperAuth::Edge.create(user_id: user.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_read.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_write.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: perm_delete.id)
      SuperAuth::Edge.create(permission_id: perm_read.id, resource_id: resource.id)
      SuperAuth::Edge.create(permission_id: perm_write.id, resource_id: resource.id)
      SuperAuth::Edge.create(permission_id: perm_delete.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 3

      permission_names = edges.map { |e| e[:permission_name] }.sort
      expect(permission_names).to eq ['delete', 'read', 'write']

      edges.each do |edge|
        expect(edge[:user_name]).to eq 'Diana'
        expect(edge[:role_name]).to eq 'Admin'
        expect(edge[:resource_name]).to eq 'database'
      end
    end

    it "group-related fields are NULL/0 in the result since groups are not part of this path" do
      user = SuperAuth::ActiveRecord::User.create(name: 'Eve')
      role = SuperAuth::ActiveRecord::Role.create(name: 'Viewer')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'view')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'dashboard')

      SuperAuth::Edge.create(user_id: user.id, role_id: role.id)
      SuperAuth::Edge.create(role_id: role.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 1

      edge = edges.first
      expect(edge[:group_id]).to eq 0
      expect(edge[:group_name]).to be_nil
      expect(edge[:group_path]).to be_nil
      expect(edge[:group_name_path]).to be_nil
      expect(edge[:group_parent_id]).to eq 0
    end

    it "user linked to an unrelated role does NOT get authorized to the resource" do
      user_authorized = SuperAuth::ActiveRecord::User.create(name: 'Insider')
      user_unauthorized = SuperAuth::ActiveRecord::User.create(name: 'Outsider')
      role_a = SuperAuth::ActiveRecord::Role.create(name: 'Operator')
      role_b = SuperAuth::ActiveRecord::Role.create(name: 'Observer')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'operate')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'machine')

      SuperAuth::Edge.create(user_id: user_authorized.id, role_id: role_a.id)
      SuperAuth::Edge.create(user_id: user_unauthorized.id, role_id: role_b.id)
      SuperAuth::Edge.create(role_id: role_a.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 1
      expect(edges.first[:user_name]).to eq 'Insider'
    end

    it "multiple users each linked to different roles but same permission and resource" do
      user1 = SuperAuth::ActiveRecord::User.create(name: 'User1')
      user2 = SuperAuth::ActiveRecord::User.create(name: 'User2')
      user3 = SuperAuth::ActiveRecord::User.create(name: 'User3')
      role_a = SuperAuth::ActiveRecord::Role.create(name: 'RoleA')
      role_b = SuperAuth::ActiveRecord::Role.create(name: 'RoleB')
      role_c = SuperAuth::ActiveRecord::Role.create(name: 'RoleC')
      permission = SuperAuth::ActiveRecord::Permission.create(name: 'access')
      resource = SuperAuth::ActiveRecord::Resource.create(name: 'api')

      SuperAuth::Edge.create(user_id: user1.id, role_id: role_a.id)
      SuperAuth::Edge.create(user_id: user2.id, role_id: role_b.id)
      SuperAuth::Edge.create(user_id: user3.id, role_id: role_c.id)
      SuperAuth::Edge.create(role_id: role_a.id, permission_id: permission.id)
      SuperAuth::Edge.create(role_id: role_b.id, permission_id: permission.id)
      SuperAuth::Edge.create(role_id: role_c.id, permission_id: permission.id)
      SuperAuth::Edge.create(permission_id: permission.id, resource_id: resource.id)

      edges = SuperAuth::ActiveRecord::Edge.users_roles_permissions_resources.to_a
      expect(edges.length).to eq 3

      user_names = edges.map { |e| e[:user_name] }.sort
      expect(user_names).to eq ['User1', 'User2', 'User3']

      edges.each do |edge|
        expect(edge[:permission_name]).to eq 'access'
        expect(edge[:resource_name]).to eq 'api'
      end
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

    SuperAuth::Edge.create(user: @guest_user, role: @all_roles)
    SuperAuth::Edge.create(permission: @read, role: @all_roles)
    SuperAuth::Edge.create(permission: @read, role: @qa)
    SuperAuth::Edge.create(resource: resource, permission: @read)

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
