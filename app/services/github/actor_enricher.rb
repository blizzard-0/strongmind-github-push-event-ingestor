module Github
  class ActorEnricher
    include Errors

    def initialize(client:, logger: Rails.logger, clock: -> { Time.current })
      @client = client
      @logger = logger
      @clock = clock
    end

    def call(github_id:, api_url:)
      return skip(:missing_github_id, github_id) if github_id.nil?
      return skip(:missing_api_url, github_id) if api_url.nil? || api_url.empty?

      log(:info, "enrichment.started", github_id:, status: :started, fetched: false)

      actor = Actor.find_by(github_id:)
      return reuse(actor) if usable?(actor)

      payload = fetch_payload(api_url)
      validate_identity!(payload, github_id)
      actor = persist(actor, github_id:, api_url:, payload:)

      log(:info, "enrichment.succeeded", github_id:, status: :fetched, fetched: true)
      EnrichmentResult.new(status: :fetched, record: actor, reason: nil, fetched: true)
    rescue Errors::Error => error
      log(
        :error,
        "enrichment.failed",
        github_id:,
        status: :failed,
        reason: error.class.name,
        fetched: true
      )
      raise
    end

    private

    attr_reader :client, :logger, :clock

    def usable?(actor)
      actor && actor.raw_payload.is_a?(Hash) && actor.raw_payload.any? && actor.enriched_at.present?
    end

    def reuse(actor)
      log(:info, "enrichment.skipped", github_id: actor.github_id, status: :reused, reason: :cached, fetched: false)
      EnrichmentResult.new(status: :reused, record: actor, reason: :cached, fetched: false)
    end

    def skip(reason, github_id)
      log(:info, "enrichment.skipped", github_id:, status: :skipped, reason:, fetched: false)
      EnrichmentResult.new(status: :skipped, record: nil, reason:, fetched: false)
    end

    def fetch_payload(api_url)
      payload = client.fetch_resource(api_url).data
      return payload if payload.is_a?(Hash)

      raise UnexpectedResponse.new(expected: Hash.name, actual: payload.class.name)
    end

    def validate_identity!(payload, github_id)
      actual_id = payload["id"]
      return if actual_id == github_id

      raise IdentityMismatch.new(expected_id: github_id, actual_id:)
    end

    def persist(actor, github_id:, api_url:, payload:)
      attributes = {
        login: payload["login"],
        api_url:,
        raw_payload: payload,
        enriched_at: clock.call
      }

      return actor.tap { |record| record.update!(attributes) } if actor

      Actor.create!(attributes.merge(github_id:))
    rescue ActiveRecord::RecordNotUnique
      concurrent_actor = Actor.find_by!(github_id:)
      return concurrent_actor if usable?(concurrent_actor)

      concurrent_actor.tap { |record| record.update!(attributes) }
    end

    def log(level, event, github_id:, status:, fetched:, reason: nil)
      fields = {
        event:,
        entity: "actor",
        github_id:,
        status:,
        fetched:
      }
      fields[:reason] = reason if reason
      logger.public_send(level, fields.map { |key, value| "#{key}=#{value}" }.join(" "))
    end
  end
end
