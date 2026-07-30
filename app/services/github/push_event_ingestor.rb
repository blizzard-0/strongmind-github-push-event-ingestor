require "securerandom"

module Github
  class PushEventIngestor
    include Errors

    COUNT_FIELDS = %i[
      fetched_count
      push_event_count
      non_push_count
      created_count
      duplicate_count
      malformed_count
      failed_count
      actor_enriched_count
      repository_enriched_count
      enrichment_reused_count
      enrichment_skipped_count
      enrichment_failed_count
    ].freeze

    def initialize(
      client: Client.new,
      parser: EventParser.new,
      actor_enricher: nil,
      repository_enricher: nil,
      logger: Rails.logger,
      clock: -> { Time.current },
      run_id_generator: -> { SecureRandom.uuid }
    )
      @client = client
      @parser = parser
      @actor_enricher = actor_enricher || ActorEnricher.new(client:, logger:, clock:)
      @repository_enricher = repository_enricher || RepositoryEnricher.new(client:, logger:, clock:)
      @logger = logger
      @clock = clock
      @run_id_generator = run_id_generator
    end

    def call
      start_run
      log(:info, "ingestion.started")

      events = fetch_events
      return finish(success: false, error: @collection_error) unless events

      @counts[:fetched_count] = events.length
      log(:info, "ingestion.events_fetched", fetched_count: events.length)
      events.each { |event| process_event(event) }

      finish(success: true)
    rescue StandardError => error
      log(:error, "ingestion.failed", reason: error.class.name, message: error.message)
      finish(success: false, error:)
    end

    private

    attr_reader :client, :parser, :actor_enricher, :repository_enricher, :logger, :clock,
      :run_id_generator

    def start_run
      @run_id = run_id_generator.call
      @started_at = clock.call
      @counts = COUNT_FIELDS.index_with(0)
      @rate_limited = false
      @rate_limit_remaining = nil
      @rate_limit_reset_at = nil
      @enrichment_stopped = false
      @collection_error = nil
    end

    def fetch_events
      response = client.fetch_events
      return response.data if response.data.is_a?(Array)

      raise UnexpectedResponse.new(expected: Array.name, actual: response.data.class.name)
    rescue Errors::Error => error
      @collection_error = error
      record_rate_limit(error)
      log_github_failure(error, scope: :collection)
      log(:error, "ingestion.failed", reason: error.class.name, message: error.message)
      nil
    end

    def process_event(event)
      parsed = parser.call(event)

      if parsed.non_push_event?
        increment(:non_push_count)
        return
      end

      increment(:push_event_count)
      if parsed.malformed?
        increment(:malformed_count)
        log(
          :warn,
          "push_event.malformed",
          github_event_id: event.is_a?(Hash) ? event["id"] : nil,
          reason: parsed.errors.map { |issue| "#{issue.field}:#{issue.code}" }.join(",")
        )
        return
      end

      persist_and_enrich(parsed.value)
    rescue StandardError => error
      increment(:failed_count)
      log(
        :error,
        "push_event.failed",
        github_event_id: event.is_a?(Hash) ? event["id"] : nil,
        reason: error.class.name,
        message: error.message
      )
    end

    def persist_and_enrich(parsed_event)
      push_event, created = persist(parsed_event)

      if created
        increment(:created_count)
        log_event("push_event.processed", parsed_event)
      else
        increment(:duplicate_count)
        log_event("push_event.duplicate", parsed_event)
      end

      enrich(push_event, parsed_event)
    end

    def persist(parsed_event)
      existing = PushEvent.find_by(github_event_id: parsed_event.github_event_id)
      return [existing, false] if existing

      attributes = parsed_event.to_h.slice(
        :github_event_id,
        :repository_github_id,
        :push_id,
        :ref,
        :head,
        :before,
        :github_created_at,
        :raw_payload
      )
      [PushEvent.create!(attributes), true]
    rescue ActiveRecord::RecordNotUnique
      [PushEvent.find_by!(github_event_id: parsed_event.github_event_id), false]
    end

    def enrich(push_event, parsed_event)
      enrich_actor(push_event, parsed_event) unless push_event.actor
      enrich_repository(push_event, parsed_event) unless push_event.repository
    end

    def enrich_actor(push_event, parsed_event)
      enrich_entity(
        push_event:,
        entity: :actor,
        github_id: parsed_event.actor_github_id,
        api_url: parsed_event.actor_api_url,
        enricher: actor_enricher,
        association: :actor
      )
    end

    def enrich_repository(push_event, parsed_event)
      enrich_entity(
        push_event:,
        entity: :repository,
        github_id: parsed_event.repository_github_id,
        api_url: parsed_event.repository_api_url,
        enricher: repository_enricher,
        association: :repository
      )
    end

    def enrich_entity(push_event:, entity:, github_id:, api_url:, enricher:, association:)
      if @enrichment_stopped
        increment(:enrichment_skipped_count)
        log_enrichment(:skipped, push_event, entity, reason: :rate_limited)
        return
      end

      result = enricher.call(github_id:, api_url:)
      case result.status
      when :fetched
        attach(push_event, association, result.record)
        increment(:"#{entity}_enriched_count")
        log_enrichment(:succeeded, push_event, entity, status: :fetched)
      when :reused
        attach(push_event, association, result.record)
        increment(:enrichment_reused_count)
        log_enrichment(:succeeded, push_event, entity, status: :reused)
      when :skipped
        increment(:enrichment_skipped_count)
        log_enrichment(:skipped, push_event, entity, reason: result.reason)
      end
    rescue Errors::Error => error
      increment(:enrichment_failed_count)
      record_rate_limit(error)
      @enrichment_stopped = true if rate_limit_error(error)
      log_enrichment(
        :failed,
        push_event,
        entity,
        reason: error.class.name,
        status_code: error.status,
        rate_limit_reset_at: @rate_limit_reset_at
      )
    rescue StandardError => error
      increment(:enrichment_failed_count)
      log_enrichment(:failed, push_event, entity, reason: error.class.name)
    end

    def attach(push_event, association, record)
      push_event.update!(association => record)
    end

    def record_rate_limit(error)
      rate_error = rate_limit_error(error)
      return unless rate_error

      @rate_limited = true
      @rate_limit_remaining = rate_error.headers[:rate_limit_remaining]
      @rate_limit_reset_at = parse_reset_at(rate_error.headers[:rate_limit_reset])
      log(
        :warn,
        "github.rate_limited",
        status_code: rate_error.status,
        remaining: @rate_limit_remaining,
        reset_at: @rate_limit_reset_at,
        retry_delay: rate_error.retry_delay
      )
      rate_error
    end

    def rate_limit_error(error)
      return error if error.is_a?(RateLimited)
      return error.last_error if error.is_a?(RetryExhausted) && error.last_error.is_a?(RateLimited)
    end

    def parse_reset_at(value)
      return if value.blank?

      Time.at(Integer(value)).utc
    rescue ArgumentError, TypeError
      value
    end

    def log_github_failure(error, scope:)
      log(
        :error,
        "github.request_failed",
        scope:,
        reason: error.class.name,
        status_code: error.status,
        remaining: error.headers[:rate_limit_remaining],
        reset_at: error.headers[:rate_limit_reset]
      )
    end

    def finish(success:, error: nil)
      completed_at = clock.call
      result = IngestionResult.new(
        run_id: @run_id,
        **@counts,
        rate_limited: @rate_limited,
        rate_limit_remaining: @rate_limit_remaining,
        rate_limit_reset_at: @rate_limit_reset_at,
        started_at: @started_at,
        completed_at:,
        elapsed_seconds: (completed_at - @started_at).to_f,
        success:,
        error:
      )
      log(success ? :info : :error, "ingestion.completed", **result.to_summary)
      result
    end

    def increment(field)
      @counts[field] += 1
    end

    def log_event(event, parsed_event)
      log(
        :info,
        event,
        github_event_id: parsed_event.github_event_id,
        repository_github_id: parsed_event.repository_github_id
      )
    end

    def log_enrichment(status, push_event, entity, **fields)
      level = status == :failed ? :error : :info
      log(
        level,
        "enrichment.#{status}",
        github_event_id: push_event.github_event_id,
        entity:,
        **fields
      )
    end

    def log(level, event, **fields)
      payload = {event:, run_id: @run_id, **fields}.compact
      logger.public_send(level, payload.map { |key, value| "#{key}=#{value}" }.join(" "))
    end
  end
end
