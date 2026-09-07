# Postgres Row-Level Security enforcement.
#
# ByCurrentUser filters queries at the ORM layer; RLS enforces the same rule
# inside Postgres, so raw SQL, `unscoped`, and non-Ruby clients are subject
# to it too — enforcing apps don't load this gem at all. Identity is
# asserted per transaction by the super_auth_become() SQL function
# (installed by `enable`): it sets transaction-local identity settings plus
# a stamp of the current transaction id, and every policy requires a stamp
# from the current transaction. Identity therefore cannot outlive its
# transaction or leak across pooled connections — a query without a fresh
# assertion sees no rows.
module SuperAuth
  module RLS
    POLICY = "super_auth".freeze

    class << self
      # Enable RLS on an app table with a policy mirroring ByCurrentUser:
      # type-level authorization rows (resource_external_id IS NULL) act as a
      # wildcard, per-record rows match on id, and system users bypass.
      #
      # One deliberate divergence: INSERTs are also gated. The policy is
      # FOR ALL with no WITH CHECK, so Postgres reuses its USING expression
      # as the implicit WITH CHECK for new rows. Creating rows therefore
      # requires a type-level authorization for the resource type, or
      # system context.
      def enable(table, resource_type:, db: SuperAuth.db)
        postgres!(db)
        create_become_function(db)
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

      # Drops the table's policy; the shared super_auth_become function is
      # left in place (other tables may still be protected, and it is
      # harmless on its own).
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
      # transaction. In nested calls the innermost assertion wins for the
      # rest of the outer transaction.
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
          db.get(Sequel.function(:super_auth_become, external_id, external_type, internal_id, system))
          yield
        end
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

      # One shared function per database; clients assert identity by calling
      # it inside their transaction. CREATE OR REPLACE keeps enable
      # idempotent.
      def create_become_function(db)
        db.run <<~SQL
          CREATE OR REPLACE FUNCTION super_auth_become(
            user_external_id text DEFAULT NULL,
            user_external_type text DEFAULT NULL,
            user_id text DEFAULT NULL,
            system boolean DEFAULT false
          ) RETURNS void LANGUAGE plpgsql AS $$
          BEGIN
            PERFORM set_config('super_auth.user_id',            COALESCE(user_id, ''), true),
                    set_config('super_auth.user_external_id',   COALESCE(user_external_id, ''), true),
                    set_config('super_auth.user_external_type', COALESCE(user_external_type, ''), true),
                    set_config('super_auth.system',             CASE WHEN system THEN 'true' ELSE '' END, true),
                    set_config('super_auth.xid',                pg_current_xact_id()::text, true);
          END
          $$;
        SQL
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
