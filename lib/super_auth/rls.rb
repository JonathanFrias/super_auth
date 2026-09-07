# Postgres Row-Level Security enforcement.
#
# ByCurrentUser filters queries at the ORM layer; RLS enforces the same rule
# inside Postgres, so raw SQL, `unscoped`, and non-Ruby clients are subject
# to it too — enforcing apps don't load this gem at all. Identity is
# asserted per transaction by two SQL functions installed by `enable`:
#
#   super_auth_become(user_external_id, user_external_type, user_id)
#     asserts a user's identity. Executable by PUBLIC.
#   super_auth_system()
#     asserts system context, which bypasses every policy. EXECUTE is
#     revoked from PUBLIC; `grant_system(role)` hands it to the roles that
#     may bypass.
#
# `enable` also grants every role SELECT on the gem's own tables, which the
# policies and the user models read, so a runtime role needs privileges on
# the application's tables and nothing else.
#
# Both set transaction-local identity settings plus a stamp of the current
# transaction id, and every policy requires a stamp from the current
# transaction. Identity therefore cannot outlive its transaction or leak
# across pooled connections — a query without a fresh assertion sees no
# rows. Both raise if the calling role is a superuser or has BYPASSRLS:
# Postgres exempts those roles from every policy, so an identity assertion
# from one would protect nothing while looking like it does.
module SuperAuth
  module RLS
    POLICY = "super_auth".freeze

    class << self
      # Enable RLS on an app table with a policy mirroring ByCurrentUser:
      # type-level authorization rows (resource_external_id IS NULL) act as a
      # wildcard, per-record rows match on id, and system context bypasses.
      #
      # One deliberate divergence: INSERTs are also gated. The policy is
      # FOR ALL with no WITH CHECK, so Postgres reuses its USING expression
      # as the implicit WITH CHECK for new rows. Creating rows therefore
      # requires a type-level authorization for the resource type, or
      # system context.
      def enable(table, resource_type:, db: SuperAuth.db)
        postgres!(db)
        create_functions(db)
        grant_runtime_reads(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.run "ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY"
        # FORCE: apply the policy even when the app connects as the table owner
        db.run "ALTER TABLE #{t} FORCE ROW LEVEL SECURITY"
        db.run "DROP POLICY IF EXISTS #{POLICY} ON #{t}"
        db.run <<~SQL
          CREATE POLICY #{POLICY} ON #{t}
          USING (
            current_setting('super_auth.xid', true) = pg_current_xact_id()::text
            AND (
              COALESCE(current_setting('super_auth.system', true), '') = 'true'
              OR EXISTS (
                SELECT 1 FROM super_auth_authorizations a
                WHERE a.resource_external_type = #{db.literal(resource_type.to_s)}
                  AND (a.resource_external_id IS NULL OR a.resource_external_id = #{t}.id)
                  AND (
                    a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')
                    OR (
                      a.user_external_id::text = NULLIF(current_setting('super_auth.user_external_id', true), '')
                      AND a.user_external_type = NULLIF(current_setting('super_auth.user_external_type', true), '')
                    )
                  )
              )
            )
          )
        SQL
      end

      # Drops the table's policy; the shared functions are left in place
      # (other tables may still be protected, and they are harmless on their
      # own).
      def disable(table, db: SuperAuth.db)
        postgres!(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.run "DROP POLICY IF EXISTS #{POLICY} ON #{t}"
        db.run "ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY"
        db.run "ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY"
      end

      # Run the block with `user`'s identity asserted for one transaction —
      # the Ruby face of the SQL contract
      # (BEGIN; SELECT super_auth_become(...); queries; COMMIT). Sequel and
      # ActiveRecord queries inside the block share the transaction's
      # connection, so the policies see the identity; it dies with the
      # transaction. A user whose `system?` is true asserts system context
      # through super_auth_system() instead, which the connection's role
      # must have been granted EXECUTE on. In nested calls the innermost
      # assertion wins for the rest of the outer transaction.
      def as(user, db: SuperAuth.db)
        postgres!(db)
        internal_id = external_id = external_type = nil
        system = user.respond_to?(:system?) && !!user.system?
        if user && internal_user?(user)
          internal_id = user.id.to_s
        elsif user
          external_id = user.id.to_s
          external_type = user.class.name
        end
        db.transaction do
          if system
            db.get(Sequel.function(:super_auth_system))
          else
            db.get(Sequel.function(:super_auth_become, external_id, external_type, internal_id))
          end
          yield
        end
      end

      # Allow `role` to assert system context: SuperAuth.as with a user whose
      # system? is true, or SELECT super_auth_system() directly. enable revokes
      # this from PUBLIC; grant it to the roles that run migrations, seeds and
      # admin jobs, and to nothing else.
      def grant_system(role, db: SuperAuth.db)
        postgres!(db)
        db.run "GRANT EXECUTE ON FUNCTION super_auth_system() TO #{db.literal(Sequel.identifier(role.to_s))}"
      end

      private

      # What any runtime role needs on the gem's own tables: the policies read
      # super_auth_authorizations as the querying role, and the user models'
      # system? reads super_auth_users. Granting PUBLIC makes enable the only
      # setup step; a deployment that wants these tables private can REVOKE
      # from PUBLIC and grant per role.
      def grant_runtime_reads(db)
        db.run "GRANT SELECT ON super_auth_authorizations, super_auth_users TO PUBLIC"
      end

      # Refuses an identity assertion from a role Postgres exempts from row
      # security: the policies would apply to nobody while everything looked
      # enforced. Checks the effective role, so a superuser session that has
      # SET ROLE to an application role passes.
      SUPERUSER_GUARD = <<~SQL.freeze
        IF (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
          RAISE EXCEPTION 'super_auth: role % is a superuser or has BYPASSRLS, so row-level security does not apply to it and asserting an identity would protect nothing. Connect as a regular role.', current_user
            USING ERRCODE = 'invalid_authorization_specification';
        END IF;
      SQL

      # Two shared functions per database; clients assert identity by calling
      # one of them inside their transaction. CREATE OR REPLACE keeps enable
      # idempotent. The pre-0.5 four-argument super_auth_become carried the
      # system bypass as its last parameter; a REPLACE with a different
      # signature would leave that overload in place, so it is dropped.
      def create_functions(db)
        db.run "DROP FUNCTION IF EXISTS super_auth_become(text, text, text, boolean)"
        db.run <<~SQL
          CREATE OR REPLACE FUNCTION super_auth_become(
            user_external_id text DEFAULT NULL,
            user_external_type text DEFAULT NULL,
            user_id text DEFAULT NULL
          ) RETURNS void LANGUAGE plpgsql AS $$
          BEGIN
            #{SUPERUSER_GUARD}
            PERFORM set_config('super_auth.user_id',            COALESCE(user_id, ''), true),
                    set_config('super_auth.user_external_id',   COALESCE(user_external_id, ''), true),
                    set_config('super_auth.user_external_type', COALESCE(user_external_type, ''), true),
                    set_config('super_auth.system',             '', true),
                    set_config('super_auth.xid',                pg_current_xact_id()::text, true);
          END
          $$;
        SQL
        db.run <<~SQL
          CREATE OR REPLACE FUNCTION super_auth_system() RETURNS void LANGUAGE plpgsql AS $$
          BEGIN
            #{SUPERUSER_GUARD}
            PERFORM set_config('super_auth.user_id',            '', true),
                    set_config('super_auth.user_external_id',   '', true),
                    set_config('super_auth.user_external_type', '', true),
                    set_config('super_auth.system',             'true', true),
                    set_config('super_auth.xid',                pg_current_xact_id()::text, true);
          END
          $$;
        SQL
        # Bypass is opt-in per role: GRANT EXECUTE ON FUNCTION super_auth_system() TO <role>.
        db.run "REVOKE EXECUTE ON FUNCTION super_auth_system() FROM PUBLIC"
      end

      def internal_user?(user)
        (defined?(SuperAuth::ActiveRecord::User) && user.is_a?(SuperAuth::ActiveRecord::User)) ||
          (defined?(SuperAuth::User) && user.is_a?(SuperAuth::User))
      end

      def postgres!(db)
        return if db.database_type == :postgres
        raise SuperAuth::Error, "SuperAuth::RLS requires Postgres (got #{db.database_type})"
      end
    end
  end
end
