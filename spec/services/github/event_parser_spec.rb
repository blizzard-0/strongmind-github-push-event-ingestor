require "rails_helper"

RSpec.describe Github::EventParser do
  subject(:parser) { described_class.new }

  def fixture(name)
    JSON.parse(Rails.root.join("spec/fixtures/github/#{name}").read)
  end

  it "extracts all structured fields from a valid PushEvent" do
    event = fixture("push_event.json")

    result = parser.call(event)

    expect(result).to be_push_event
    expect(result.errors).to be_empty
    expect(result.warnings).to be_empty
    expect(result.value.to_h).to include(
      github_event_id: event.fetch("id"),
      repository_github_id: event.dig("repo", "id"),
      push_id: event.dig("payload", "push_id"),
      ref: event.dig("payload", "ref"),
      head: event.dig("payload", "head"),
      before: event.dig("payload", "before"),
      github_created_at: Time.iso8601(event.fetch("created_at")),
      actor_github_id: event.dig("actor", "id"),
      actor_api_url: event.dig("actor", "url"),
      repository_api_url: event.dig("repo", "url"),
      raw_payload: event
    )
  end

  it "preserves the complete raw event object" do
    event = fixture("push_event.json")

    expect(parser.call(event).value.raw_payload).to equal(event)
  end

  it "identifies non-PushEvents without treating them as malformed" do
    event = fixture("events.json").find { |candidate| candidate["type"] != "PushEvent" }

    result = parser.call(event)

    expect(result).to be_non_push_event
    expect(result.value).to be_nil
    expect(result.errors).to be_empty
  end

  it "returns structured errors for malformed required PushEvent fields" do
    result = parser.call(fixture("malformed_push_event.json"))

    expect(result).to be_malformed
    expect(result.value).to be_nil
    expect(result.errors.map(&:field)).to include(:push_id, :before, :github_created_at)
    expect(result.errors.map(&:code)).to all(be_in([:missing_or_invalid, :invalid]))
  end

  it "validates every field required for durable PushEvent persistence" do
    removals = {
      github_event_id: ->(event) { event.delete("id") },
      repository_github_id: ->(event) { event.fetch("repo").delete("id") },
      push_id: ->(event) { event.fetch("payload").delete("push_id") },
      ref: ->(event) { event.fetch("payload").delete("ref") },
      head: ->(event) { event.fetch("payload").delete("head") },
      before: ->(event) { event.fetch("payload").delete("before") }
    }

    removals.each do |field, remove|
      event = fixture("push_event.json")
      remove.call(event)
      result = parser.call(event)

      expect(result).to be_malformed
      expect(result.errors.map(&:field)).to include(field)
    end
  end

  it "keeps missing enrichment identifiers and URLs non-fatal" do
    event = fixture("push_event.json")
    event["actor"] = {}
    event.fetch("repo").delete("url")
    event.dig("payload", "repository")&.delete("url")

    result = parser.call(event)

    expect(result).to be_push_event
    expect(result.value.actor_github_id).to be_nil
    expect(result.value.actor_api_url).to be_nil
    expect(result.value.repository_api_url).to be_nil
    expect(result.warnings.map(&:field)).to contain_exactly(
      :actor_github_id,
      :actor_api_url,
      :repository_api_url
    )
  end

  it "uses an actual repository URL embedded in the payload when repo.url is absent" do
    event = fixture("push_event.json")
    event.fetch("repo").delete("url")
    payload_url = event.dig("payload", "repository", "url")

    result = parser.call(event)

    expect(result).to be_push_event
    expect(result.value.repository_api_url).to eq(payload_url)
  end

  it "does not invent an enrichment URL when the event provides none" do
    event = fixture("push_event.json")
    event.fetch("repo").delete("url")
    event.fetch("payload").delete("repository")

    result = parser.call(event)

    expect(result).to be_push_event
    expect(result.value.repository_api_url).to be_nil
    expect(result.warnings.map(&:field)).to include(:repository_api_url)
  end

  it "rejects invalid timestamps" do
    event = fixture("push_event.json")
    event["created_at"] = "not-a-timestamp"

    result = parser.call(event)

    expect(result).to be_malformed
    expect(result.errors.map(&:field)).to include(:github_created_at)
  end

  it "handles unexpected top-level and nested shapes without raising" do
    expect(parser.call([])).to be_malformed

    {
      "payload" => [],
      "repo" => "not-an-object",
      "actor" => []
    }.each do |field, value|
      event = fixture("push_event.json")
      event[field] = value

      expect { parser.call(event) }.not_to raise_error
      expect(parser.call(event)).to be_malformed
    end
  end

  it "rejects missing or invalid event types" do
    missing_type = fixture("push_event.json").tap { |event| event.delete("type") }

    expect(parser.call(missing_type)).to be_malformed
    expect(parser.call({"type" => 123})).to be_malformed
  end
end
