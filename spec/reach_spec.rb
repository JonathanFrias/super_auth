require "spec_helper"

# The reach map is pure normalisation; nothing here touches the database.
# Both RLS.enable and the ORM macro build their steps from it, so every
# shape it accepts and every shape it refuses is the contract those two
# layers share.
RSpec.describe SuperAuth::Reach do
  def normalize(**options)
    described_class.normalize(**options)
  end

  describe ".normalize" do
    it "puts the per-record step first, under :id, with no parents by default" do
      expect(normalize(resource_type: "Claim")).to eq(id: ["Claim"])
    end

    it "takes a list of types for the per-record step, deduplicated in order" do
      expect(normalize(resource_type: %w[Claim Claim::Writable Claim]))
        .to eq(id: %w[Claim Claim::Writable])
    end

    it "adds one step per parent Hash, keyed by the column as a Symbol" do
      reach = normalize(resource_type: "Claim",
                        parent: { column: :organization_id, resource_type: "Organization::Member" })

      expect(reach).to eq(id: ["Claim"], organization_id: ["Organization::Member"])
    end

    it "accepts the column as a String and still keys by Symbol" do
      reach = normalize(resource_type: "Claim",
                        parent: { column: "organization_id", resource_type: "Organization::Member" })

      expect(reach.keys).to eq %i[id organization_id]
    end

    it "takes an Array of parent Hashes, keeping their order after :id" do
      reach = normalize(resource_type: "Medium",
                        parent: [{ column: :claim_id, resource_type: "Claim" },
                                 { column: :organization_id, resource_type: "Organization::Member" }])

      expect(reach.keys).to eq %i[id claim_id organization_id]
    end

    it "takes a list of types per parent, deduplicated in order" do
      reach = normalize(resource_type: "Claim",
                        parent: { column: :organization_id,
                                  resource_type: %w[Organization::Admin Organization::Member Organization::Admin] })

      expect(reach[:organization_id]).to eq %w[Organization::Admin Organization::Member]
    end

    it "treats an empty parent list the same as none" do
      expect(normalize(resource_type: "Claim", parent: [])).to eq(id: ["Claim"])
    end

    # Both layers store the map on a class attribute / rebuild a policy from
    # it; a shared map one caller could mutate would drift the other.
    it "returns a frozen map of frozen lists that leaves the caller's strings alone" do
      type = +"Claim"
      reach = normalize(resource_type: [type])

      expect(reach).to be_frozen
      expect(reach[:id]).to be_frozen
      expect(reach[:id].first).to be_frozen
      expect(type).not_to be_frozen
    end

    describe "refusals" do
      it "refuses an empty or non-String per-record type" do
        [nil, "", [], [""], :Claim, ["Claim", nil]].each do |value|
          expect { normalize(resource_type: value) }
            .to raise_error(SuperAuth::Error, /resource_type: must be a String or a non-empty Array of Strings/)
        end
      end

      it "refuses a parent that is neither a Hash nor an Array of Hashes" do
        ["organization_id", :organization_id, [:organization_id]].each do |value|
          expect { normalize(resource_type: "Claim", parent: value) }
            .to raise_error(SuperAuth::Error, /parent: must be a Hash \{column:, resource_type:\}/)
        end
      end

      it "refuses a parent Hash with a key other than column: and resource_type:" do
        parent = { column: :organization_id, resource_type: "Organization::Member", check: true }

        expect { normalize(resource_type: "Claim", parent: parent) }
          .to raise_error(SuperAuth::Error, /parent: must be a Hash \{column:, resource_type:\}/)
      end

      it "refuses a parent without a column name" do
        [{ resource_type: "Organization::Member" },
         { column: nil, resource_type: "Organization::Member" },
         { column: "", resource_type: "Organization::Member" },
         { column: 3, resource_type: "Organization::Member" }].each do |parent|
          expect { normalize(resource_type: "Claim", parent: parent) }
            .to raise_error(SuperAuth::Error, /parent: column: must be a Symbol or String naming a column/)
        end
      end

      it "refuses :id as a parent column, since that is the per-record step" do
        [:id, "id"].each do |column|
          expect { normalize(resource_type: "Claim", parent: { column: column, resource_type: "Claim" }) }
            .to raise_error(SuperAuth::Error, /parent: column: :id is the per-record step/)
        end
      end

      it "refuses the same column declared twice, whether as Symbol or String" do
        parent = [{ column: :organization_id, resource_type: "Organization::Member" },
                  { column: "organization_id", resource_type: "Organization::Admin" }]

        expect { normalize(resource_type: "Claim", parent: parent) }
          .to raise_error(SuperAuth::Error, /parent: column :organization_id is declared twice/)
      end

      it "refuses an empty or non-String parent type, naming the column" do
        [nil, "", [], [""], :Organization].each do |value|
          expect { normalize(resource_type: "Claim", parent: { column: :organization_id, resource_type: value }) }
            .to raise_error(SuperAuth::Error, /parent: organization_id resource_type: must be a String or a non-empty Array of Strings/)
        end
      end
    end
  end

  describe ".parents" do
    it "is the column steps without the per-record one" do
      reach = normalize(resource_type: "Claim",
                        parent: { column: :organization_id, resource_type: "Organization::Member" })

      expect(described_class.parents(reach)).to eq(organization_id: ["Organization::Member"])
    end

    it "is empty when only the per-record step was declared" do
      expect(described_class.parents(normalize(resource_type: "Claim"))).to eq({})
    end
  end
end
