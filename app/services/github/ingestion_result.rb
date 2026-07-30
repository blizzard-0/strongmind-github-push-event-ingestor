module Github
  IngestionResult = Data.define(
    :run_id,
    :fetched_count,
    :push_event_count,
    :non_push_count,
    :created_count,
    :duplicate_count,
    :malformed_count,
    :failed_count,
    :actor_enriched_count,
    :repository_enriched_count,
    :enrichment_reused_count,
    :enrichment_skipped_count,
    :enrichment_failed_count,
    :rate_limited,
    :rate_limit_remaining,
    :rate_limit_reset_at,
    :started_at,
    :completed_at,
    :elapsed_seconds,
    :success,
    :error
  ) do
    def success?
      success
    end

    def to_summary
      to_h.slice(
        :run_id,
        :fetched_count,
        :push_event_count,
        :non_push_count,
        :created_count,
        :duplicate_count,
        :malformed_count,
        :failed_count,
        :actor_enriched_count,
        :repository_enriched_count,
        :enrichment_reused_count,
        :enrichment_skipped_count,
        :enrichment_failed_count,
        :rate_limited,
        :rate_limit_reset_at,
        :elapsed_seconds,
        :success
      )
    end
  end
end
