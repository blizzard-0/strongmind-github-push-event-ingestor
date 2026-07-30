require "rails_helper"

RSpec.describe Github::PushEventIngestor do
  subject(:ingestor) do
    described_class.new(
      client:,
      parser:,
      actor_enricher:,
      repository_enricher:,
      logger:,
      clock:,
      run_id_generator: -> { "run-123" }
    )
  end

  let(:client) { instance_double(Github::Client) }
  let(:parser) { Github::EventParser.new }
  let(:logger) { instance_spy(ActiveSupport::Logger) }
  let(:clock) { -> { Time.utc(2026, 7, 30, 12) } }
  let(:actor_enricher) { Github::ActorEnricher.new(client:, logger:, clock:) }
  let(:repository_enricher) { Github::RepositoryEnricher.new(client:, logger:, clock:) }
  let(:events) { fixture("events.json") }
  let(:actor_payload) { fixture("actor.json") }
  let(:repository_payload) { fixture("repository.json") }

  def fixture(name)
    JSON.parse(Rails.root.join("spec/fixtures/github/#{name}").read)
  end

  def collection_response(data)
    Github::Client::Response.new(data:, headers: {}, status: 200)
  end

  before do
    allow(client).to receive(:fetch_events).and_return(collection_response(events))
    allow(client).to receive(:fetch_resource) do |url|
      data = url.include?("/users/") ? actor_payload : repository_payload
      Github::Client::Response.new(data:, headers: {}, status: 200)
    end
  end

  it "filters a mixed collection and persists, enriches, and summarizes the PushEvent" do
    result = ingestor.call
    event = PushEvent.find_by!(github_event_id: "event-10001")

    expect(result).to be_success
    expect(result.to_summary).to include(
      run_id: "run-123",
      fetched_count: 2,
      push_event_count: 1,
      non_push_count: 1,
      created_count: 1,
      duplicate_count: 0,
      malformed_count: 0,
      actor_enriched_count: 1,
      repository_enriched_count: 1
    )
    expect(event).to have_attributes(
      repository_github_id: 2001,
      push_id: 3001,
      ref: "refs/heads/main",
      head: "abc123",
      before: "def456",
      actor: Actor.find_by!(github_id: 1001),
      repository: Repository.find_by!(github_id: 2001)
    )
    expect(event.raw_payload).to eq(events.first)
    expect(PushEvent.count).to eq(1)
  end

  it "persists the PushEvent before attempting either enrichment" do
    actor = instance_double(Github::ActorEnricher)
    repository = instance_double(Github::RepositoryEnricher)
    allow(actor).to receive(:call) do
      expect(PushEvent.exists?(github_event_id: "event-10001")).to be(true)
      Github::EnrichmentResult.new(status: :skipped, record: nil, reason: :test, fetched: false)
    end
    allow(repository).to receive(:call) do
      expect(PushEvent.exists?(github_event_id: "event-10001")).to be(true)
      Github::EnrichmentResult.new(status: :skipped, record: nil, reason: :test, fetched: false)
    end
    ordered_ingestor = described_class.new(
      client:,
      parser:,
      actor_enricher: actor,
      repository_enricher: repository,
      logger:,
      clock:
    )

    expect(ordered_ingestor.call).to be_success
  end

  it "preserves the event and continues when actor enrichment fails" do
    actor = instance_double(Github::ActorEnricher)
    allow(actor).to receive(:call).and_raise(
      Github::Errors::PermanentHttpFailure.new("actor unavailable", status: 404)
    )
    failure_ingestor = described_class.new(
      client:,
      parser:,
      actor_enricher: actor,
      repository_enricher:,
      logger:,
      clock:
    )

    result = failure_ingestor.call

    expect(result).to be_success
    expect(result.enrichment_failed_count).to eq(1)
    expect(PushEvent.find_by!(github_event_id: "event-10001")).to be_persisted
  end

  it "preserves the event when repository enrichment fails" do
    repository = instance_double(Github::RepositoryEnricher)
    allow(repository).to receive(:call).and_raise(
      Github::Errors::RetryExhausted.new(
        attempts: 3,
        last_error: Github::Errors::TransientHttpFailure.new("unavailable", status: 503)
      )
    )
    failure_ingestor = described_class.new(
      client:,
      parser:,
      actor_enricher:,
      repository_enricher: repository,
      logger:,
      clock:
    )

    result = failure_ingestor.call

    expect(result).to be_success
    expect(result.enrichment_failed_count).to eq(1)
    expect(PushEvent.find_by!(github_event_id: "event-10001")).to be_persisted
  end

  it "is idempotent across repeated ingestion runs" do
    first = ingestor.call
    second = ingestor.call

    expect(first.created_count).to eq(1)
    expect(second.created_count).to eq(0)
    expect(second.duplicate_count).to eq(1)
    expect(PushEvent.where(github_event_id: "event-10001").count).to eq(1)
  end

  it "handles a database uniqueness race as a duplicate" do
    allow(PushEvent).to receive(:create!) do |attributes|
      PushEvent.new(attributes).tap(&:save!)
      raise ActiveRecord::RecordNotUnique
    end

    result = ingestor.call

    expect(result.duplicate_count).to eq(1)
    expect(result.created_count).to eq(0)
    expect(PushEvent.where(github_event_id: "event-10001").count).to eq(1)
  end

  it "repairs missing enrichment on a duplicate without replacing its raw payload" do
    original_payload = {"id" => "original-payload"}
    PushEvent.create!(
      github_event_id: "event-10001",
      repository_github_id: 2001,
      push_id: 3001,
      ref: "refs/heads/main",
      head: "abc123",
      before: "def456",
      raw_payload: original_payload
    )

    result = ingestor.call
    event = PushEvent.find_by!(github_event_id: "event-10001")

    expect(result.duplicate_count).to eq(1)
    expect(event.raw_payload).to eq(original_payload)
    expect(event.actor).to be_present
    expect(event.repository).to be_present
  end

  it "skips malformed PushEvents and continues to a later valid event" do
    later_event = fixture("push_event.json").tap { |event| event["id"] = "event-later" }
    allow(client).to receive(:fetch_events).and_return(
      collection_response([fixture("malformed_push_event.json"), later_event])
    )

    result = ingestor.call

    expect(result).to be_success
    expect(result.malformed_count).to eq(1)
    expect(result.created_count).to eq(1)
    expect(PushEvent.pluck(:github_event_id)).to contain_exactly("event-later")
  end

  it "isolates an unexpected individual parser failure" do
    broken = {"id" => "broken", "type" => "PushEvent"}
    valid = fixture("push_event.json").tap { |event| event["id"] = "event-after-error" }
    allow(client).to receive(:fetch_events).and_return(collection_response([broken, valid]))
    allow(parser).to receive(:call).and_wrap_original do |original, event|
      raise "unexpected parser failure" if event["id"] == "broken"

      original.call(event)
    end

    result = ingestor.call

    expect(result.failed_count).to eq(1)
    expect(result.created_count).to eq(1)
    expect(PushEvent.exists?(github_event_id: "event-after-error")).to be(true)
  end

  it "returns a failed result when the source collection cannot be fetched" do
    failure = Github::Errors::RetryExhausted.new(
      attempts: 3,
      last_error: Github::Errors::TransientHttpFailure.new("unavailable", status: 503)
    )
    allow(client).to receive(:fetch_events).and_raise(failure)

    result = ingestor.call

    expect(result).not_to be_success
    expect(result.error).to equal(failure)
    expect(result.fetched_count).to eq(0)
    expect(PushEvent.count).to eq(0)
  end

  it "preserves collection rate-limit metadata in a failed result" do
    reset = Time.utc(2026, 7, 30, 12, 5).to_i.to_s
    failure = Github::Errors::RateLimited.new(
      "limited",
      retry_delay: 120,
      status: 429,
      headers: {rate_limit_remaining: "0", rate_limit_reset: reset}
    )
    allow(client).to receive(:fetch_events).and_raise(failure)

    result = ingestor.call

    expect(result).not_to be_success
    expect(result.rate_limited).to be(true)
    expect(result.rate_limit_remaining).to eq("0")
    expect(result.rate_limit_reset_at).to eq(Time.at(reset.to_i).utc)
  end

  it "stops enrichment fan-out after rate limiting while continuing persistence" do
    second_event = fixture("push_event.json").tap do |event|
      event["id"] = "event-10003"
      event["payload"]["push_id"] = 3003
    end
    allow(client).to receive(:fetch_events).and_return(collection_response([events.first, second_event]))
    actor = instance_double(Github::ActorEnricher)
    repository = instance_double(Github::RepositoryEnricher)
    rate_error = Github::Errors::RateLimited.new(
      "limited",
      retry_delay: 120,
      status: 429,
      headers: {rate_limit_remaining: "0", rate_limit_reset: "1785432600"}
    )
    allow(actor).to receive(:call).once.and_raise(rate_error)
    allow(repository).to receive(:call)
    limited_ingestor = described_class.new(
      client:,
      parser:,
      actor_enricher: actor,
      repository_enricher: repository,
      logger:,
      clock:
    )

    result = limited_ingestor.call

    expect(result).to be_success
    expect(result.created_count).to eq(2)
    expect(result.enrichment_failed_count).to eq(1)
    expect(result.enrichment_skipped_count).to eq(3)
    expect(result.rate_limited).to be(true)
    expect(actor).to have_received(:call).once
    expect(repository).not_to have_received(:call)
  end

  it "emits required lifecycle logs without raw payloads" do
    ingestor.call

    expect(logger).to have_received(:info).with(include("event=ingestion.started", "run_id=run-123"))
    expect(logger).to have_received(:info).with(include("event=ingestion.events_fetched", "fetched_count=2"))
    expect(logger).to have_received(:info).with(include("event=push_event.processed"))
    expect(logger).to have_received(:info).with(include("event=ingestion.completed", "success=true"))
    expect(logger).not_to have_received(:info).with(include("raw_payload"))
  end
end
