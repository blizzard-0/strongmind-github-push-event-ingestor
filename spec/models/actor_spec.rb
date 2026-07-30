require "rails_helper"

RSpec.describe Actor, type: :model do
  let(:valid_attributes) do
    {
      github_id: 10_001,
      login: "octocat",
      api_url: "https://api.github.com/users/octocat",
      raw_payload: { "id" => 10_001, "profile" => { "type" => "User" } },
      enriched_at: Time.zone.parse("2026-07-30 12:00:00")
    }
  end

  it "has many push events" do
    association = described_class.reflect_on_association(:push_events)

    expect(association.macro).to eq(:has_many)
    expect(association.class_name).to eq("PushEvent")
  end

  it "requires a GitHub ID and API URL" do
    actor = described_class.new(valid_attributes.except(:github_id, :api_url))

    expect(actor).not_to be_valid
    expect(actor.errors).to include(:github_id, :api_url)
  end

  it "validates GitHub ID uniqueness" do
    described_class.create!(valid_attributes)
    duplicate = described_class.new(valid_attributes.merge(api_url: "https://api.github.com/users/other"))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_id]).to include("has already been taken")
  end

  it "preserves the complete JSONB payload" do
    actor = described_class.create!(valid_attributes)

    expect(actor.reload.raw_payload).to eq(valid_attributes[:raw_payload])
  end

  it "rejects non-object payloads through model validation" do
    actor = described_class.new(valid_attributes.merge(raw_payload: ["not", "an", "object"]))

    expect(actor).not_to be_valid
    expect(actor.errors[:raw_payload]).to include("must be a JSON object")
  end

  it "enforces GitHub ID uniqueness in PostgreSQL" do
    described_class.create!(valid_attributes)
    duplicate = described_class.new(valid_attributes)

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces required columns in PostgreSQL" do
    actor = described_class.new(valid_attributes.merge(api_url: nil))

    expect { actor.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "enforces JSON object payloads in PostgreSQL" do
    actor = described_class.new(valid_attributes.merge(raw_payload: ["not", "an", "object"]))

    expect { actor.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
