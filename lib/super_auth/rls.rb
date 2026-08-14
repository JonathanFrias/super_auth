# Postgres Row-Level Security enforcement.
#
# ByCurrentUser filters queries at the ORM layer; RLS enforces the same rule
# inside Postgres, so raw SQL, `unscoped`, and other database clients cannot
# see unauthorized rows either. Identity travels in session settings
# (super_auth.user_id / user_external_id / user_external_type / system),
# mirrored from SuperAuth.current_user= when SuperAuth.rls is true.
module SuperAuth
  module RLS
    POLICY = "super_auth".freeze

    class << self
      # Enable RLS on an app table with a policy mirroring ByCurrentUser:
      # type-level authorization rows (resource_external_id IS NULL) act as a
      # wildcard, per-record rows match on id, and system users bypass.
      #
      # One deliberate divergence: INSERTs are also gated. Postgres applies
      # the SELECT policy to INSERT ... RETURNING (which ActiveRecord and
      # Sequel use to fetch the new id), so a row invisible to its creator
      # can't be inserted anyway. Creating rows therefore requires a
      # type-level authorization for the resource type, or system context.
      def enable(table, resource_type:, db: SuperAuth.db)
        postgres!(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.run "ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY"
        # FORCE: apply the policy even when the app connects as the table owner
        db.run "ALTER TABLE #{t} FORCE ROW LEVEL SECURITY"
        db.run "DROP POLICY IF EXISTS #{POLICY} ON #{t}"
        db.run <<~SQL
          CREATE POLICY #{POLICY} ON #{t}
          USING (
            COALESCE(current_setting('super_auth.system', true), '') = 'true'
            OR EXISTS (
              SELECT 1 FROM super_auth_authorizations a
              WHERE a.resource_external_type = #{db.literal(resource_type.to_s)}
                AND (a.resource_external_id IS NULL OR a.resource_external_id = #{t}.id::text)
                AND (
                  a.user_id::text = NULLIF(current_setting('super_auth.user_id', true), '')
                  OR (
                    a.user_external_id = NULLIF(current_setting('super_auth.user_external_id', true), '')
                    AND a.user_external_type = NULLIF(current_setting('super_auth.user_external_type', true), '')
                  )
                )
            )
          )
        SQL
      end

      def disable(table, db: SuperAuth.db)
        postgres!(db)
        t = db.literal(Sequel.identifier(table.to_s))
        db.run "DROP POLICY IF EXISTS #{POLICY} ON #{t}"
        db.run "ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY"
        db.run "ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY"
      end

      # Mirror a user's identity into session settings read by the policies.
      # nil clears identity, so queries see no rows (same as ByCurrentUser
      # with missing_user_behavior :none).
      def apply_user(user, db: SuperAuth.db)
        postgres!(db)
        internal_id = external_id = external_type = system = ""
        if user
          system = "true" if user.respond_to?(:system?) && user.system?
          if internal_user?(user)
            internal_id = user.id.to_s
          else
            external_id = user.id.to_s
            external_type = user.class.name
          end
        end
        set(db,
          "super_auth.user_id" => internal_id,
          "super_auth.user_external_id" => external_id,
          "super_auth.user_external_type" => external_type,
          "super_auth.system" => system)
      end

      def clear(db: SuperAuth.db)
        apply_user(nil, db: db)
      end

      private

      def internal_user?(user)
        (defined?(SuperAuth::ActiveRecord::User) && user.is_a?(SuperAuth::ActiveRecord::User)) ||
          (defined?(SuperAuth::User) && user.is_a?(SuperAuth::User))
      end

      def set(db, settings)
        # set_config with is_local: false = session-scoped. Assumes the
        # connection stays pinned to this thread (standard Rails behavior);
        # incompatible with transaction-mode poolers like pgbouncer.
        settings.each { |name, value| db.get(Sequel.function(:set_config, name, value, false)) }
      end

      def postgres!(db)
        return if db.database_type == :postgres
        raise SuperAuth::Error, "SuperAuth::RLS requires Postgres (got #{db.database_type})"
      end
    end
  end
end
