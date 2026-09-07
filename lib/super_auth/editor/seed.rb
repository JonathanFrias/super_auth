require "super_auth"

module SuperAuth
  class Editor
    # Sample graph for the editor. "Acme Cloud": three departments that are
    # deliberately DISJOINT. Engineering, Finance, and Support each have their
    # own users, roles, permissions, and resources with no shared nodes, so
    # traversal is obvious: click anyone in Engineering and only Engineering
    # lights up.
    #
    # The hierarchy matches how grants inherit:
    #   - The shared "Developer" role is attached to the Engineering PARENT
    #     group, so every engineer (Backend + Frontend) inherits it, while
    #     Backend and Frontend each also hold a child-group grant the other
    #     does not.
    #   - "Support Lead" is the PARENT role of "Support Agent": a lead inherits
    #     the agent's abilities plus refunds; an agent does not get refunds.
    #
    # Special people:
    #   - Riley (Auditor): read-only into BOTH Finance and Support
    #   - Morgan (Admin): direct user->resource access across departments
    #   - Nina (New Hire): no access at all
    #
    # Destructive: run! replaces the whole graph, including the compiled
    # authorizations. Only ever runs on request (super_auth-editor --seed).
    module Seed
      module_function

      # Returns the row counts per table.
      def run!
        SuperAuth.db.transaction do
          clear!

          grp = SuperAuth::Group
          rol = SuperAuth::Role
          usr = SuperAuth::User
          perm_m = SuperAuth::Permission
          res_m = SuperAuth::Resource
          edg = SuperAuth::Edge

          # ===== GROUPS (Engineering is a parent of Backend + Frontend) =====
          engineering = grp.create(name: "Engineering")
          backend     = grp.create(name: "Backend",  parent_id: engineering.id)
          frontend    = grp.create(name: "Frontend", parent_id: engineering.id)
          finance     = grp.create(name: "Finance")
          support     = grp.create(name: "Customer Support")

          # ===== ROLES (Support Lead is the parent of Support Agent) =====
          developer     = rol.create(name: "Developer")
          sre           = rol.create(name: "SRE")
          accountant    = rol.create(name: "Accountant")
          support_lead  = rol.create(name: "Support Lead")
          support_agent = rol.create(name: "Support Agent", parent_id: support_lead.id)

          # ===== PERMISSIONS (disjoint per department) =====
          merge_code     = perm_m.create(name: "merge_code")
          read_repo      = perm_m.create(name: "read_repo")
          deploy         = perm_m.create(name: "deploy")
          run_migrations = perm_m.create(name: "run_migrations")   # Backend-only
          publish_site   = perm_m.create(name: "publish_site")     # Frontend-only
          restart_server = perm_m.create(name: "restart_server")   # SRE-only
          view_ledger    = perm_m.create(name: "view_ledger")
          issue_invoice  = perm_m.create(name: "issue_invoice")
          run_payroll    = perm_m.create(name: "run_payroll")
          view_ticket    = perm_m.create(name: "view_ticket")
          close_ticket   = perm_m.create(name: "close_ticket")
          issue_refund   = perm_m.create(name: "issue_refund")     # Support Lead-only

          # ===== RESOURCES (disjoint per department) =====
          source_repo        = res_m.create(name: "source_repo")
          production_cluster = res_m.create(name: "production_cluster")
          staging_cluster    = res_m.create(name: "staging_cluster")
          app_database       = res_m.create(name: "app_database")      # Backend
          marketing_site     = res_m.create(name: "marketing_site")    # Frontend
          general_ledger     = res_m.create(name: "general_ledger")
          invoices           = res_m.create(name: "invoices")
          support_tickets    = res_m.create(name: "support_tickets")
          customer_accounts  = res_m.create(name: "customer_accounts")

          # ===== USERS =====
          alice  = usr.create(name: "Alice")   # Backend dev
          bob    = usr.create(name: "Bob")     # Frontend dev
          sam    = usr.create(name: "Sam")     # SRE
          carol  = usr.create(name: "Carol")   # Accountant
          dave   = usr.create(name: "Dave")    # Accountant
          erin   = usr.create(name: "Erin")    # Support agent
          frank  = usr.create(name: "Frank")   # Support lead
          riley  = usr.create(name: "Riley")   # Auditor (cross-department, read-only)
          morgan = usr.create(name: "Morgan")  # Admin (direct resource access)
          usr.create(name: "Nina")             # New hire, no access yet

          # ===== ENGINEERING =====
          edg.create(user_id: alice.id, group_id: backend.id)
          edg.create(user_id: bob.id,   group_id: frontend.id)
          # Shared Developer role on the PARENT group: both Alice and Bob inherit it
          edg.create(group_id: engineering.id, role_id: developer.id)
          edg.create(role_id: developer.id, permission_id: merge_code.id)
          edg.create(role_id: developer.id, permission_id: read_repo.id)
          edg.create(role_id: developer.id, permission_id: deploy.id)
          edg.create(permission_id: merge_code.id, resource_id: source_repo.id)
          edg.create(permission_id: read_repo.id,  resource_id: source_repo.id)
          edg.create(permission_id: deploy.id,     resource_id: production_cluster.id)
          edg.create(permission_id: deploy.id,     resource_id: staging_cluster.id)
          # Child-group-specific grants (Alice gets one, Bob the other)
          edg.create(group_id: backend.id,  permission_id: run_migrations.id)
          edg.create(permission_id: run_migrations.id, resource_id: app_database.id)
          edg.create(group_id: frontend.id, permission_id: publish_site.id)
          edg.create(permission_id: publish_site.id, resource_id: marketing_site.id)
          # Sam is an SRE via a direct role assignment
          edg.create(user_id: sam.id, role_id: sre.id)
          edg.create(role_id: sre.id, permission_id: restart_server.id)
          edg.create(role_id: sre.id, permission_id: deploy.id)
          edg.create(permission_id: restart_server.id, resource_id: production_cluster.id)

          # ===== FINANCE =====
          edg.create(user_id: carol.id, group_id: finance.id)
          edg.create(user_id: dave.id,  group_id: finance.id)
          edg.create(group_id: finance.id, role_id: accountant.id)
          edg.create(role_id: accountant.id, permission_id: view_ledger.id)
          edg.create(role_id: accountant.id, permission_id: issue_invoice.id)
          edg.create(role_id: accountant.id, permission_id: run_payroll.id)
          edg.create(permission_id: view_ledger.id,   resource_id: general_ledger.id)
          edg.create(permission_id: issue_invoice.id, resource_id: invoices.id)
          edg.create(permission_id: run_payroll.id,   resource_id: general_ledger.id)

          # ===== SUPPORT (Lead inherits Agent's abilities via the role hierarchy) =====
          edg.create(user_id: erin.id,  group_id: support.id)
          edg.create(user_id: frank.id, group_id: support.id)
          edg.create(user_id: frank.id, role_id: support_lead.id)     # Frank is a lead
          edg.create(group_id: support.id, role_id: support_agent.id) # everyone is at least an agent
          edg.create(role_id: support_agent.id, permission_id: view_ticket.id)
          edg.create(role_id: support_agent.id, permission_id: close_ticket.id)
          edg.create(role_id: support_lead.id,  permission_id: issue_refund.id)
          edg.create(permission_id: view_ticket.id,  resource_id: support_tickets.id)
          edg.create(permission_id: close_ticket.id, resource_id: support_tickets.id)
          edg.create(permission_id: issue_refund.id, resource_id: customer_accounts.id)

          # ===== CROSS-CUTTERS =====
          # Riley audits both the ledger and tickets (direct permission grants).
          edg.create(user_id: riley.id, permission_id: view_ledger.id)
          edg.create(user_id: riley.id, permission_id: view_ticket.id)
          # Morgan has direct resource access across departments (simplest path).
          edg.create(user_id: morgan.id, resource_id: production_cluster.id)
          edg.create(user_id: morgan.id, resource_id: general_ledger.id)
          edg.create(user_id: morgan.id, resource_id: support_tickets.id)

          counts
        end
      end

      # Empties the graph and the compiled table. Parents are detached first:
      # MySQL checks the self-referencing key row by row.
      def clear!
        SuperAuth::Edge.dataset.delete
        SuperAuth::Authorization.dataset.delete
        [SuperAuth::Group, SuperAuth::Role].each { |m| m.dataset.update(parent_id: nil) }
        [SuperAuth::Group, SuperAuth::Role, SuperAuth::User, SuperAuth::Permission, SuperAuth::Resource].each do |m|
          m.dataset.delete
        end
      end

      def counts
        {
          groups: SuperAuth::Group.count, roles: SuperAuth::Role.count, users: SuperAuth::User.count,
          permissions: SuperAuth::Permission.count, resources: SuperAuth::Resource.count, edges: SuperAuth::Edge.count,
        }
      end
    end
  end
end
