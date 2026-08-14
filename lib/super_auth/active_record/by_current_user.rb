module SuperAuth::ActiveRecord::ByCurrentUser
  def self.included(base)
    base.send(:default_scope, **{all_queries: true}) do
      if SuperAuth.current_user.blank?
        raise SuperAuth::Error, "SuperAuth.current_user not set" if SuperAuth.missing_user_behavior == :raise
        next none
      end

      if SuperAuth.current_user.respond_to?(:system?) && SuperAuth.current_user.system?
        self
      else
        user_where =
        if SuperAuth.current_user.is_a?(SuperAuth::ActiveRecord::User)
          { user_id: SuperAuth.current_user.id }
        else
          { user_external_id: SuperAuth.current_user.id, user_external_type: SuperAuth.current_user.class.name }
        end

        resource_type = self.model.name

        # Type-level authorization (resource_external_id IS NULL) acts as wildcard:
        # user has access to ALL records of this type (e.g., admin with ADMIN_ACCESS).
        type_level = SuperAuth::ActiveRecord::Authorization
          .where(**user_where, resource_external_type: resource_type, resource_external_id: nil)

        if type_level.exists?
          self
        else
          # Per-record authorization: filter to specific records the user can access.
          # Cast the pk to text: resource_external_id is a string column, and
          # Postgres refuses integer = text (SQLite coerces silently).
          per_record = SuperAuth::ActiveRecord::Authorization
            .where(**user_where, resource_external_type: resource_type)
            .where.not(resource_external_id: nil)
            .select(:resource_external_id)
          cast_type = model.connection.adapter_name.match?(/mysql/i) ? "CHAR" : "TEXT"
          quoted_pk = "#{model.connection.quote_table_name(model.table_name)}.#{model.connection.quote_column_name(model.primary_key)}"
          where("CAST(#{quoted_pk} AS #{cast_type}) IN (#{per_record.to_sql})")
        end
      end
    end
  end

  module ClassMethods
  end
end
