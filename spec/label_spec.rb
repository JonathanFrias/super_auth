require "spec_helper"
require "active_record"

# belongs_to :external resolves its class by name, so the stand-in for a
# host's model needs a real constant and a real table.
class SuperAuthLabelSpecClaim < ActiveRecord::Base
  self.table_name = "super_auth_label_spec_claims"
end

RSpec.describe "resource labels" do
  let(:db) { SuperAuth.db }

  before do
    SuperAuth.install_migrations
    SuperAuth.load
    db[:super_auth_edges].delete
    db[:super_auth_resources].delete
    db.create_table?(:super_auth_label_spec_claims) do
      primary_key :id
      String :name
    end
    db[:super_auth_label_spec_claims].delete
    SuperAuthLabelSpecClaim.reset_column_information
  end

  after do
    db.drop_table?(:super_auth_label_spec_claims)
  end

  describe "SuperAuth.label_for" do
    it "prefers super_auth_label, then name, then title" do
      explicit = Struct.new(:super_auth_label, :name, :title).new("explicit", "n", "t")
      named = Struct.new(:name, :title).new("n", "t")
      titled = Struct.new(:title).new("t")

      expect(SuperAuth.label_for(explicit)).to eq "explicit"
      expect(SuperAuth.label_for(named)).to eq "n"
      expect(SuperAuth.label_for(titled)).to eq "t"
    end

    it "falls through a blank value instead of stopping on it" do
      blank = Struct.new(:super_auth_label, :name, :title).new(nil, "", "t")
      expect(SuperAuth.label_for(blank)).to eq "t"
    end

    it "returns nil rather than to_s when the record answers none of them" do
      expect(SuperAuth.label_for(Object.new)).to be_nil
      expect(SuperAuth.label_for(nil)).to be_nil
    end
  end

  describe "SuperAuth::ActiveRecord::Resource" do
    let(:claim) { SuperAuthLabelSpecClaim.create!(name: "Gulf War presumptive") }

    def resource_for(claim)
      SuperAuth::ActiveRecord::Resource.create!(name: "SuperAuthLabelSpecClaim", external: claim)
    end

    it "labels a node from its external record when the node is saved" do
      expect(resource_for(claim).reload.super_auth_label).to eq "Gulf War presumptive"
    end

    it "re-derives the label after the external record is renamed" do
      resource = resource_for(claim)
      claim.update!(name: "Agent Orange presumptive")

      resource.reload.refresh_label!

      expect(resource.reload.super_auth_label).to eq "Agent Orange presumptive"
    end

    it "is a no-op on a type-level row, which has no record to name" do
      resource = SuperAuth::ActiveRecord::Resource.create!(name: "SuperAuthLabelSpecClaim")

      expect { resource.refresh_label! }.not_to change { resource.reload.super_auth_label }
      expect(resource.reload.super_auth_label).to be_nil
    end

    # The branch RLS depends on: an unreadable external record derives nil,
    # and nil must degrade to the stale label rather than erase it.
    it "never overwrites a stored label with a nil derivation" do
      resource = resource_for(claim)
      claim.destroy!

      resource.reload.refresh_label!
      resource.reload.save!

      expect(resource.reload.super_auth_label).to eq "Gulf War presumptive"
    end
  end
end
