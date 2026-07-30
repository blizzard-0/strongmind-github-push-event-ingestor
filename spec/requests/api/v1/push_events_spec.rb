require "rails_helper"

RSpec.describe "API V1 PushEvents" do
  def json
    response.parsed_body
  end

  def create_event(
    github_event_id:,
    github_created_at:,
    actor: nil,
    repository: nil,
    raw_payload: {"type" => "PushEvent"}
  )
    PushEvent.create!(
      github_event_id:,
      repository_github_id: 2001,
      push_id: github_event_id.delete("^0-9").to_i,
      ref: "refs/heads/main",
      head: "abc123",
      before: "def456",
      github_created_at:,
      raw_payload:,
      actor:,
      repository:
    )
  end

  describe "GET /api/v1/push_events" do
    it "returns persisted events newest first with pagination metadata" do
      older = create_event(github_event_id: "event-1", github_created_at: 2.hours.ago)
      newer = create_event(github_event_id: "event-2", github_created_at: 1.hour.ago)

      get "/api/v1/push_events"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(json.fetch("push_events").pluck("id")).to eq([newer.id, older.id])
      expect(json.fetch("pagination")).to eq(
        "page" => 1,
        "per_page" => 20,
        "total_count" => 2,
        "total_pages" => 1
      )
    end

    it "orders missing GitHub timestamps after timestamped records, then by ID" do
      missing_first = create_event(github_event_id: "event-1", github_created_at: nil)
      missing_second = create_event(github_event_id: "event-2", github_created_at: nil)
      timestamped = create_event(github_event_id: "event-3", github_created_at: 1.hour.ago)

      get "/api/v1/push_events"

      expect(json.fetch("push_events").pluck("id")).to eq(
        [timestamped.id, missing_second.id, missing_first.id]
      )
    end

    it "paginates without loading the full collection" do
      events = 5.times.map do |number|
        create_event(
          github_event_id: "event-#{number + 1}",
          github_created_at: number.minutes.ago
        )
      end

      get "/api/v1/push_events", params: {page: 2, per_page: 2}

      expect(json.fetch("push_events").pluck("id")).to eq([events[2].id, events[3].id])
      expect(json.fetch("pagination")).to include(
        "page" => 2,
        "per_page" => 2,
        "total_count" => 5,
        "total_pages" => 3
      )
    end

    it "caps per_page at 100" do
      create_event(github_event_id: "event-1", github_created_at: 1.hour.ago)

      get "/api/v1/push_events", params: {per_page: 1_000}

      expect(response).to have_http_status(:ok)
      expect(json.dig("pagination", "per_page")).to eq(100)
    end

    it "uses safe defaults for invalid pagination values" do
      create_event(github_event_id: "event-1", github_created_at: 1.hour.ago)

      [
        {page: "invalid", per_page: "invalid"},
        {page: 0, per_page: 0},
        {page: -1, per_page: -1}
      ].each do |params|
        get "/api/v1/push_events", params: params

        expect(response).to have_http_status(:ok)
        expect(json.fetch("pagination")).to include("page" => 1, "per_page" => 20)
      end
    end

    it "includes enrichment summaries and excludes raw payloads" do
      actor = Actor.create!(
        github_id: 1001,
        login: "octocat",
        api_url: "https://api.github.com/users/octocat",
        raw_payload: {"id" => 1001},
        enriched_at: Time.current
      )
      repository = Repository.create!(
        github_id: 2001,
        name: "octocat/hello-world",
        api_url: "https://api.github.com/repos/octocat/hello-world",
        raw_payload: {"id" => 2001},
        enriched_at: Time.current
      )
      create_event(
        github_event_id: "event-1",
        github_created_at: 1.hour.ago,
        actor:,
        repository:,
        raw_payload: {"private" => "large payload"}
      )

      get "/api/v1/push_events"

      item = json.fetch("push_events").first
      expect(item).to include(
        "actor" => {"github_id" => 1001, "login" => "octocat"},
        "repository" => {"github_id" => 2001, "name" => "octocat/hello-world"}
      )
      expect(item).not_to have_key("raw_payload")
    end

    it "filters by GitHub event ID when requested" do
      wanted = create_event(github_event_id: "event-wanted", github_created_at: 1.hour.ago)
      create_event(github_event_id: "event-other", github_created_at: 2.hours.ago)

      get "/api/v1/push_events", params: {github_event_id: "event-wanted"}

      expect(json.fetch("push_events").pluck("id")).to eq([wanted.id])
      expect(json.dig("pagination", "total_count")).to eq(1)
    end

    it "preloads actor and repository associations" do
      actor = Actor.create!(
        github_id: 1001,
        login: "octocat",
        api_url: "https://api.github.com/users/octocat",
        raw_payload: {"id" => 1001},
        enriched_at: Time.current
      )
      repository = Repository.create!(
        github_id: 2001,
        name: "octocat/hello-world",
        api_url: "https://api.github.com/repos/octocat/hello-world",
        raw_payload: {"id" => 2001},
        enriched_at: Time.current
      )
      3.times do |number|
        create_event(
          github_event_id: "event-#{number}",
          github_created_at: number.minutes.ago,
          actor:,
          repository:
        )
      end
      association_queries = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        association_queries << sql if sql.match?(/FROM "(actors|repositories)"/)
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "/api/v1/push_events"
      end

      expect(association_queries.grep(/FROM "actors"/).size).to eq(1)
      expect(association_queries.grep(/FROM "repositories"/).size).to eq(1)
    end
  end

  describe "GET /api/v1/push_events/:id" do
    it "returns structured fields, enrichment summaries, and the complete raw payload" do
      actor = Actor.create!(
        github_id: 1001,
        login: "octocat",
        api_url: "https://api.github.com/users/octocat",
        raw_payload: {"id" => 1001},
        enriched_at: Time.current
      )
      repository = Repository.create!(
        github_id: 2001,
        name: "octocat/hello-world",
        api_url: "https://api.github.com/repos/octocat/hello-world",
        raw_payload: {"id" => 2001},
        enriched_at: Time.current
      )
      raw_payload = {"id" => "event-1", "payload" => {"commits" => [{"sha" => "abc123"}]}}
      event = create_event(
        github_event_id: "event-1",
        github_created_at: Time.utc(2026, 7, 30, 12),
        actor:,
        repository:,
        raw_payload:
      )

      get "/api/v1/push_events/#{event.id}"

      expect(response).to have_http_status(:ok)
      expect(json).to include(
        "id" => event.id,
        "github_event_id" => "event-1",
        "repository_github_id" => 2001,
        "push_id" => 1,
        "ref" => "refs/heads/main",
        "head" => "abc123",
        "before" => "def456",
        "github_created_at" => "2026-07-30T12:00:00.000Z",
        "actor" => {"github_id" => 1001, "login" => "octocat"},
        "repository" => {"github_id" => 2001, "name" => "octocat/hello-world"},
        "raw_payload" => raw_payload
      )
      expect(json.fetch("created_at")).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "supports missing optional enrichment associations" do
      event = create_event(github_event_id: "event-1", github_created_at: 1.hour.ago)

      get "/api/v1/push_events/#{event.id}"

      expect(response).to have_http_status(:ok)
      expect(json).to include("actor" => nil, "repository" => nil)
    end

    it "returns a JSON 404 for a missing record" do
      get "/api/v1/push_events/999999999"

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq("application/json")
      expect(json).to eq("error" => "PushEvent not found")
    end
  end
end
