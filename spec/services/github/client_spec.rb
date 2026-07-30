require "rails_helper"

RSpec.describe Github::Client do
  subject(:client) do
    described_class.new(
      max_attempts: 3,
      max_retry_delay: 60,
      sleeper: ->(seconds) { delays << seconds },
      clock: -> { Time.utc(2026, 7, 30, 12) }
    )
  end

  let(:delays) { [] }
  let(:events_url) { described_class::EVENTS_URL }
  let(:response_headers) do
    {
      "X-RateLimit-Limit" => "60",
      "X-RateLimit-Remaining" => "59",
      "X-RateLimit-Reset" => "1785430860",
      "ETag" => '"events-etag"',
      "Last-Modified" => "Thu, 30 Jul 2026 11:59:00 GMT"
    }
  end

  def fixture(name)
    Rails.root.join("spec/fixtures/github/#{name}").read
  end

  describe "#fetch_events" do
    it "uses GitHub API headers and returns data with relevant response metadata" do
      request = stub_request(:get, events_url)
        .with(
          headers: {
            "Accept" => described_class::ACCEPT,
            "User-Agent" => described_class::USER_AGENT
          }
        )
        .to_return(status: 200, body: fixture("events.json"), headers: response_headers)

      response = client.fetch_events

      expect(request).to have_been_requested.once
      expect(response.data).to be_an(Array)
      expect(response.status).to eq(200)
      expect(response.headers).to include(
        rate_limit_limit: "60",
        rate_limit_remaining: "59",
        rate_limit_reset: "1785430860",
        etag: '"events-etag"',
        last_modified: "Thu, 30 Jul 2026 11:59:00 GMT"
      )
    end

    it "rejects malformed JSON" do
      request = stub_request(:get, events_url)
        .to_return(status: 200, body: fixture("malformed_json.txt"))

      expect { client.fetch_events }.to raise_error(Github::Errors::MalformedJson)
      expect(request).to have_been_requested.once
    end

    it "rejects an unexpected collection response shape" do
      stub_request(:get, events_url).to_return(status: 200, body: fixture("actor.json"))

      expect { client.fetch_events }
        .to raise_error(Github::Errors::UnexpectedResponse, /Expected.*Array.*Hash/)
    end

    it "does not retry permanent failures" do
      request = stub_request(:get, events_url)
        .to_return(status: 404, body: '{"message":"Not Found"}')

      expect { client.fetch_events }
        .to raise_error(Github::Errors::PermanentHttpFailure, "Not Found")
      expect(request).to have_been_requested.once
      expect(delays).to be_empty
    end

    it "retries transient server failures with bounded exponential backoff" do
      request = stub_request(:get, events_url).to_return(
        {status: 503, body: fixture("server_error.json")},
        {status: 502, body: fixture("server_error.json")},
        {status: 200, body: fixture("events.json")}
      )

      expect(client.fetch_events.status).to eq(200)
      expect(request).to have_been_requested.times(3)
      expect(delays).to eq([1, 2])
    end

    it "raises a retry exhaustion error after the configured attempt limit" do
      request = stub_request(:get, events_url)
        .to_return(status: 503, body: fixture("server_error.json"))

      expect { client.fetch_events }.to raise_error(Github::Errors::RetryExhausted) do |error|
        expect(error.attempts).to eq(3)
        expect(error.last_error).to be_a(Github::Errors::TransientHttpFailure)
        expect(error.status).to eq(503)
      end
      expect(request).to have_been_requested.times(3)
      expect(delays).to eq([1, 2])
    end

    it "retries network timeouts" do
      request = stub_request(:get, events_url)
        .to_timeout.then
        .to_return(status: 200, body: fixture("events.json"))

      expect(client.fetch_events.status).to eq(200)
      expect(request).to have_been_requested.times(2)
      expect(delays).to eq([1])
    end

    it "uses Retry-After for HTTP 429 responses" do
      request = stub_request(:get, events_url).to_return(
        {
          status: 429,
          body: fixture("rate_limit.json"),
          headers: {"Retry-After" => "2", "X-RateLimit-Remaining" => "0"}
        },
        {status: 200, body: fixture("events.json")}
      )

      expect(client.fetch_events.status).to eq(200)
      expect(request).to have_been_requested.times(2)
      expect(delays).to eq([2.0])
    end

    it "recognizes a rate-limited HTTP 403 and uses the reset time" do
      request = stub_request(:get, events_url).to_return(
        {
          status: 403,
          body: fixture("rate_limit.json"),
          headers: {
            "X-RateLimit-Remaining" => "0",
            "X-RateLimit-Reset" => Time.utc(2026, 7, 30, 12, 0, 10).to_i.to_s
          }
        },
        {status: 200, body: fixture("events.json")}
      )

      expect(client.fetch_events.status).to eq(200)
      expect(request).to have_been_requested.times(2)
      expect(delays).to eq([10])
    end

    it "returns a rate-limit error instead of sleeping for an unreasonable delay" do
      request = stub_request(:get, events_url).to_return(
        status: 429,
        body: fixture("rate_limit.json"),
        headers: {"Retry-After" => "120"}
      )

      expect { client.fetch_events }.to raise_error(Github::Errors::RateLimited) do |error|
        expect(error.retry_delay).to eq(120.0)
        expect(error.status).to eq(429)
      end
      expect(request).to have_been_requested.once
      expect(delays).to be_empty
    end
  end

  describe "#fetch_resource" do
    it "fetches actor and repository objects from supplied GitHub API URLs" do
      actor_url = "https://api.github.com/users/octocat"
      repository_url = "https://api.github.com/repos/octocat/hello-world"
      stub_request(:get, actor_url).to_return(status: 200, body: fixture("actor.json"))
      stub_request(:get, repository_url).to_return(status: 200, body: fixture("repository.json"))

      expect(client.fetch_resource(actor_url).data).to include("login" => "octocat")
      expect(client.fetch_resource(repository_url).data).to include("name" => "hello-world")
    end

    it "rejects an unexpected object response shape" do
      url = "https://api.github.com/users/octocat"
      stub_request(:get, url).to_return(status: 200, body: fixture("events.json"))

      expect { client.fetch_resource(url) }
        .to raise_error(Github::Errors::UnexpectedResponse, /Expected.*Hash.*Array/)
    end

    it "allows only HTTPS URLs on api.github.com" do
      invalid_urls = [
        "http://api.github.com/events",
        "https://example.com/events",
        "https://api.github.com:444/events",
        "https://user@api.github.com/events",
        "not a URL"
      ]

      invalid_urls.each do |url|
        expect { client.fetch_resource(url) }
          .to raise_error(Github::Errors::InvalidUrl), "expected #{url.inspect} to be rejected"
      end
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  it "blocks unstubbed external network connections in the test suite" do
    expect { Net::HTTP.get(URI("https://example.com")) }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end
end
