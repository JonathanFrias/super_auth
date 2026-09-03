require "spec_helper"
require "active_record"

# Findings from the September 2026 test audit, pinned as specs. Nothing here is
# fixed yet. See spec/audit/graph_spec.rb for the pending/tripwire convention and
# ~/.claude/plans/superauth-audit-fix-handoff.md for the full context (D1).
RSpec.describe "Audit: the ActiveRecord migrations versus the Sequel migrations" do
  let(:db) { SuperAuth.db }
  let(:ar_migrations) { File.expand_path("../../db/migrate_activerecord", __dir__) }

  SUPER_AUTH_TABLES = %i[
    super_auth_users super_auth_groups super_auth_permissions super_auth_roles
    super_auth_resources super_auth_edges super_auth_authorizations
  ].freeze

  # What an application depends on: per table, per column, the database type,
  # nullability and whether it is the primary key.
  def schema_snapshot
    SUPER_AUTH_TABLES.to_h do |table|
      [table, db.schema(table).to_h { |name, info| [name, [info[:db_type], info[:allow_null], !!info[:primary_key]]] }]
    end
  end

  # Referencing tables first, so foreign keys never block a drop.
  def drop_everything
    (%i[super_auth_authorizations super_auth_edges super_auth_groups super_auth_roles
        super_auth_users super_auth_permissions super_auth_resources
        schema_info schema_migrations ar_internal_metadata]).each do |table|
      db.drop_table?(table)
    end
  end

  it "D1: the ActiveRecord migrations produce the same schema as the Sequel migrations" do
    pending "D1: known divergences: only ActiveRecord gives super_auth_authorizations a primary key; parent_id is bigint (AR) vs integer (Sequel); string columns differ in length limits per adapter"
    begin
      SuperAuth.uninstall_migrations
    rescue SuperAuth::Error
    end
    drop_everything

    ActiveRecord::MigrationContext.new(ar_migrations).migrate
    from_active_record = schema_snapshot
    ActiveRecord::MigrationContext.new(ar_migrations).migrate(0)
    drop_everything

    SuperAuth.install_migrations
    from_sequel = schema_snapshot

    expect(from_active_record).to eq from_sequel
  ensure
    drop_everything
    SuperAuth.install_migrations
    SuperAuth.refresh_model_schemas
  end
end
