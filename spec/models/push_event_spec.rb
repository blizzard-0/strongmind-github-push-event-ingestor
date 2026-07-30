require "rails_helper"

RSpec.describe PushEvent, type: :model do
  let(:valid_attributes) do
    {
      github_event_id: "event-10001",
      repository_github_id: 20_001,
      push_id: 30_001,
      ref: "refs/heads/main",
      head: "abc123",
      before: "def456",
      github_created_at: Time.zone.parse("2026-07-30 12:00:00"),
      raw_payload: {
        "id" => "event-10001",
        "payload" => { "push_id" => 30_001, "commits" => [{ "sha" => "abc123" }] }
      }
    }
  end

  it "belongs to optional actor and repository enrichment" do
    actor_association = described_class.reflect_on_association(:actor)
    repository_association = described_class.reflect_on_association(:repository)
    event = described_class.new(valid_attributes)

    expect(actor_association.macro).to eq(:belongs_to)
    expect(repository_association.macro).to eq(:belongs_to)
    expect(event).to be_valid
    expect(event.actor).to be_nil
    expect(event.repository).to be_nil
  end

  it "can associate actor and repository enrichment" do
    actor = Actor.create!(
      github_id: 10_001,
      api_url: "https://api.github.com/users/octocat"
    )
    repository = Repository.create!(
      github_id: 20_001,
      api_url: "https://api.github.com/repos/octocat/hello-world"
    )

    event = described_class.create!(valid_attributes.merge(actor:, repository:))

    expect(event.reload.actor).to eq(actor)
    expect(event.repository).to eq(repository)
    expect(actor.push_events).to contain_exactly(event)
    expect(repository.push_events).to contain_exactly(event)
  end

  it "requires all structured event fields" do
    required_fields = %i[github_event_id repository_github_id push_id ref head before]

    required_fields.each do |field|
      event = described_class.new(valid_attributes.merge(field => nil))

      expect(event).not_to be_valid
      expect(event.errors[field]).to include("can't be blank")
    end
  end

  it "validates GitHub event ID uniqueness" do
    described_class.create!(valid_attributes)
    duplicate = described_class.new(valid_attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_event_id]).to include("has already been taken")
  end

  it "preserves the complete raw GitHub event payload" do
    event = described_class.create!(valid_attributes)

    expect(event.reload.raw_payload).to eq(valid_attributes[:raw_payload])
  end

  it "rejects non-object payloads through model validation" do
    event = described_class.new(valid_attributes.merge(raw_payload: []))

    expect(event).not_to be_valid
    expect(event.errors[:raw_payload]).to include("must be a JSON object")
  end

  it "enforces GitHub event ID uniqueness in PostgreSQL" do
    described_class.create!(valid_attributes)
    duplicate = described_class.new(valid_attributes)

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces required structured fields in PostgreSQL" do
    event = described_class.new(valid_attributes.merge(head: nil))

    expect { event.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "enforces JSON object payloads in PostgreSQL" do
    event = described_class.new(valid_attributes.merge(raw_payload: []))

    expect { event.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "enforces actor foreign keys in PostgreSQL" do
    event = described_class.new(valid_attributes.merge(actor_id: -1))

    expect { event.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "enforces repository foreign keys in PostgreSQL" do
    event = described_class.new(valid_attributes.merge(repository_id: -1))

    expect { event.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
