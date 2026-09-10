require "spec_helper"

# A host requires the Sequel models before it has connected anything, so
# Sequel binds them to whatever Sequel::Model.db is at that moment — a mock,
# in a Rails boot. A model left on that binding answers db.database_type
# wrong and runs its queries nowhere; the first consumer's Authorization
# class sat on a mock for months and 0.9.0's compile! was the first code to
# depend on the binding. These pin that SuperAuth rebinds every model to
# SuperAuth.db, and that compile! runs there even before it does.
RSpec.describe "Sequel model binding" do
  let(:db) { SuperAuth.db }
  let(:models) { %w[User Group Permission Role Resource Edge Authorization].map { |name| SuperAuth.const_get(name) } }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_authorizations].delete
    db[:super_auth_edges].delete
    db[:super_auth_users].delete
    db[:super_auth_resources].update(parent_id: nil)
    db[:super_auth_resources].delete
  end

  after do
    # Whatever an example did to the bindings, the rest of the suite gets
    # the real database back.
    SuperAuth.refresh_model_schemas
  end

  # The way a host's boot binds them: a dataset on whatever database Sequel
  # had at the time. Sequel refuses Model.db= once a dataset exists.
  def bind_to_a_mock(model)
    model.set_dataset(Sequel.mock[model.table_name])
    expect(model.db.database_type).to eq :mock
  end

  it "rebinds every model to SuperAuth.db when the schemas are refreshed" do
    models.each { |model| bind_to_a_mock(model) }
    SuperAuth.refresh_model_schemas
    models.each { |model| expect(model.db).to equal(db) }
    expect(SuperAuth::User.columns).to include(:name)
  end

  it "moves the binding even before the tables exist, and the columns follow the migrations" do
    bind_to_a_mock(SuperAuth::Authorization)
    SuperAuth.uninstall_migrations
    expect { SuperAuth.refresh_model_schemas }.not_to raise_error
    expect(SuperAuth::Authorization.db).to equal(db)
    SuperAuth.install_migrations
    expect(SuperAuth::Authorization.columns).to include(:resource_external_id)
  end

  it "rebinds when SuperAuth.db is assigned" do
    bind_to_a_mock(SuperAuth::Authorization)
    SuperAuth.db = db
    expect(SuperAuth::Authorization.db).to equal(db)
  end

  it "compiles on SuperAuth.db even while Authorization is bound elsewhere" do
    user = db[:super_auth_users].insert(name: "u")
    resource = db[:super_auth_resources].insert(name: "r", external_type: "Doc", external_id: "1")
    db[:super_auth_edges].insert(user_id: user, resource_id: resource)
    bind_to_a_mock(SuperAuth::Authorization)

    # The Postgres branch — the timestamp cast — must follow SuperAuth.db,
    # not the model's binding: that is the branch the consumer's failure went
    # through.
    if db.database_type == :postgres
      expect(SuperAuth::Authorization.compile_source.sql).to include("AS timestamp")
    end
    expect(SuperAuth::Authorization.compile!).to eq 1
    expect(db[:super_auth_authorizations].count).to eq 1
  end
end
