require "rails_helper"

RSpec.describe Github::RepositoryEnricher do
  subject(:enricher) { described_class.new(client:, logger:, clock:) }

  let(:client) { instance_double(Github::Client) }
  let(:logger) { instance_spy(ActiveSupport::Logger) }
  let(:clock) { -> { Time.utc(2026, 7, 30, 12) } }
  let(:github_id) { 2001 }
  let(:api_url) { "https://api.github.com/repos/octocat/hello-world" }
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/github/repository.json").read) }
  let(:response) { Github::Client::Response.new(data: payload, headers: {}, status: 200) }

  before { allow(client).to receive(:fetch_resource).and_return(response) }

  it "fetches and durably persists a new repository with its complete payload" do
    result = enricher.call(github_id:, api_url:)

    expect(result).to be_fetched
    expect(result.record).to be_persisted
    expect(result.record).to have_attributes(
      github_id:,
      name: "octocat/hello-world",
      api_url:,
      enriched_at: clock.call
    )
    expect(result.record.raw_payload).to eq(payload)
    expect(Repository.find_by(github_id:).raw_payload).to eq(payload)
    expect(client).to have_received(:fetch_resource).with(api_url).once
  end

  it "falls back to the short repository name when full_name is unavailable" do
    payload.delete("full_name")

    expect(enricher.call(github_id:, api_url:).record.name).to eq("hello-world")
  end

  it "reuses usable cached enrichment without an HTTP request" do
    repository = Repository.create!(
      github_id:,
      name: "cached",
      api_url:,
      raw_payload: {"id" => github_id, "name" => "cached"},
      enriched_at: 1.year.ago
    )

    result = enricher.call(github_id:, api_url:)

    expect(result).to be_reused
    expect(result.record).to eq(repository)
    expect(result.fetched).to be(false)
    expect(client).not_to have_received(:fetch_resource)
  end

  it "refreshes an existing repository whose enrichment is incomplete" do
    repository = Repository.create!(github_id:, api_url:, raw_payload: {}, enriched_at: nil)

    result = enricher.call(github_id:, api_url:)

    expect(result).to be_fetched
    expect(result.record).to eq(repository)
    expect(repository.reload.raw_payload).to eq(payload)
    expect(repository.enriched_at).to eq(clock.call)
    expect(client).to have_received(:fetch_resource).once
  end

  it "skips missing GitHub IDs without creating a record or fetching" do
    result = enricher.call(github_id: nil, api_url:)

    expect(result).to be_skipped
    expect(result.reason).to eq(:missing_github_id)
    expect(Repository.count).to eq(0)
    expect(client).not_to have_received(:fetch_resource)
  end

  it "skips missing API URLs without creating a record or fetching" do
    result = enricher.call(github_id:, api_url: nil)

    expect(result).to be_skipped
    expect(result.reason).to eq(:missing_api_url)
    expect(Repository.count).to eq(0)
    expect(client).not_to have_received(:fetch_resource)
  end

  it "rejects identity mismatches without persisting the payload" do
    payload["id"] = 9999

    expect { enricher.call(github_id:, api_url:) }
      .to raise_error(Github::Errors::IdentityMismatch) do |error|
        expect(error.expected_id).to eq(github_id)
        expect(error.actual_id).to eq(9999)
      end
    expect(Repository.count).to eq(0)
  end

  it "reuses a valid record created during a uniqueness race" do
    concurrent = nil
    allow(Repository).to receive(:create!) do
      concurrent = Repository.new(
        github_id:,
        name: "concurrent",
        api_url:,
        raw_payload: {"id" => github_id},
        enriched_at: clock.call
      )
      concurrent.save!
      raise ActiveRecord::RecordNotUnique
    end

    result = enricher.call(github_id:, api_url:)

    expect(result).to be_fetched
    expect(result.record).to eq(concurrent)
    expect(Repository.where(github_id:).count).to eq(1)
  end

  it "preserves client failure information" do
    failure = Github::Errors::RetryExhausted.new(
      attempts: 3,
      last_error: Github::Errors::TransientHttpFailure.new("unavailable", status: 503)
    )
    allow(client).to receive(:fetch_resource).and_raise(failure)

    expect { enricher.call(github_id:, api_url:) }.to raise_error(failure)
  end

  it "preserves permanent resource failures" do
    failure = Github::Errors::PermanentHttpFailure.new("not found", status: 404)
    allow(client).to receive(:fetch_resource).and_raise(failure)

    expect { enricher.call(github_id:, api_url:) }.to raise_error(failure) do |error|
      expect(error.status).to eq(404)
    end
  end

  it "preserves rate-limit metadata" do
    failure = Github::Errors::RateLimited.new(
      "limited",
      retry_delay: 30,
      status: 429,
      headers: {rate_limit_reset: "1785430860"}
    )
    allow(client).to receive(:fetch_resource).and_raise(failure)

    expect { enricher.call(github_id:, api_url:) }.to raise_error(failure) do |error|
      expect(error.retry_delay).to eq(30)
      expect(error.headers[:rate_limit_reset]).to eq("1785430860")
    end
  end

  it "emits structured lifecycle logs without raw payloads" do
    enricher.call(github_id:, api_url:)

    expect(logger).to have_received(:info).with(include("event=enrichment.started", "entity=repository"))
    expect(logger).to have_received(:info).with(include("event=enrichment.succeeded", "fetched=true"))
    expect(logger).not_to have_received(:info).with(include("raw_payload"))
  end

  it "logs skipped and failed enrichment with concise reasons" do
    enricher.call(github_id: nil, api_url:)
    failure = Github::Errors::PermanentHttpFailure.new("not found", status: 404)
    allow(client).to receive(:fetch_resource).and_raise(failure)

    expect { enricher.call(github_id:, api_url:) }.to raise_error(failure)
    expect(logger).to have_received(:info).with(include(
      "event=enrichment.skipped",
      "reason=missing_github_id",
      "fetched=false"
    ))
    expect(logger).to have_received(:error).with(include(
      "event=enrichment.failed",
      "reason=Github::Errors::PermanentHttpFailure",
      "fetched=false"
    ))
  end
end
