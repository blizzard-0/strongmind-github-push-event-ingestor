require "time"

module Github
  class EventParser
    Issue = Data.define(:field, :code, :message)

    ParsedEvent = Data.define(
      :github_event_id,
      :repository_github_id,
      :push_id,
      :ref,
      :head,
      :before,
      :github_created_at,
      :actor_github_id,
      :actor_api_url,
      :repository_api_url,
      :raw_payload
    )

    Result = Data.define(:status, :value, :errors, :warnings) do
      def push_event?
        status == :push_event
      end

      def non_push_event?
        status == :non_push_event
      end

      def malformed?
        status == :malformed
      end
    end

    def call(event)
      return malformed_event_shape(event) unless event.is_a?(Hash)
      return missing_type_result if blank_string?(event["type"])
      return result(:non_push_event) unless event["type"] == "PushEvent"

      parse_push_event(event)
    end

    private

    def parse_push_event(event)
      errors = []
      warnings = []
      payload = object_at(event, "payload", errors)
      repository = object_at(event, "repo", errors)
      actor = optional_object_at(event, "actor", errors, warnings)

      attributes = {
        github_event_id: required_string(event["id"], :github_event_id, errors),
        repository_github_id: required_integer(repository["id"], :repository_github_id, errors),
        push_id: required_integer(payload["push_id"], :push_id, errors),
        ref: required_string(payload["ref"], :ref, errors),
        head: required_string(payload["head"], :head, errors),
        before: required_string(payload["before"], :before, errors),
        github_created_at: parsed_timestamp(event["created_at"], errors),
        actor_github_id: optional_integer(actor["id"], :actor_github_id, errors, warnings),
        actor_api_url: optional_url(actor["url"], :actor_api_url, errors, warnings),
        repository_api_url: repository_api_url(event, errors, warnings),
        raw_payload: event
      }

      return result(:malformed, errors:) if errors.any?

      result(:push_event, value: ParsedEvent.new(**attributes), warnings:)
    end

    def object_at(event, key, errors)
      value = event[key]
      return value if value.is_a?(Hash)

      errors << issue(key.to_sym, :unexpected_shape, "#{key} must be an object")
      {}
    end

    def optional_object_at(event, key, errors, warnings)
      value = event[key]
      if value.nil?
        warnings << issue(key.to_sym, :missing_optional, "#{key} is missing")
        return {}
      end
      return value if value.is_a?(Hash)

      errors << issue(key.to_sym, :unexpected_shape, "#{key} must be an object")
      {}
    end

    def required_string(value, field, errors)
      return value if value.is_a?(String) && !value.empty?

      errors << issue(field, :missing_or_invalid, "#{field} must be a non-empty string")
      nil
    end

    def required_integer(value, field, errors)
      return value if value.is_a?(Integer)

      errors << issue(field, :missing_or_invalid, "#{field} must be an integer")
      nil
    end

    def optional_integer(value, field, errors, warnings)
      if value.nil?
        warnings << issue(field, :missing_optional, "#{field} is missing")
        return
      end
      return value if value.is_a?(Integer)

      errors << issue(field, :invalid, "#{field} must be an integer")
      nil
    end

    def optional_url(value, field, errors, warnings)
      if value.nil?
        warnings << issue(field, :missing_optional, "#{field} is missing")
        return
      end
      return value if value.is_a?(String) && !value.empty?

      errors << issue(field, :invalid, "#{field} must be a non-empty string")
      nil
    end

    def repository_api_url(event, errors, warnings)
      repo_url = event.dig("repo", "url") if event["repo"].is_a?(Hash)
      payload_url = event.dig("payload", "repository", "url") if event.dig("payload", "repository").is_a?(Hash)

      optional_url(repo_url || payload_url, :repository_api_url, errors, warnings)
    end

    def parsed_timestamp(value, errors)
      return if value.nil?

      unless value.is_a?(String)
        errors << issue(:github_created_at, :invalid, "github_created_at must be an ISO 8601 string")
        return
      end

      Time.iso8601(value)
    rescue ArgumentError
      errors << issue(:github_created_at, :invalid, "github_created_at must be a valid ISO 8601 timestamp")
      nil
    end

    def malformed_event_shape(event)
      result(
        :malformed,
        errors: [issue(:event, :unexpected_shape, "event must be an object, got #{event.class}")]
      )
    end

    def missing_type_result
      result(
        :malformed,
        errors: [issue(:type, :missing_or_invalid, "event type must be a non-empty string")]
      )
    end

    def result(status, value: nil, errors: [], warnings: [])
      Result.new(status:, value:, errors:, warnings:)
    end

    def issue(field, code, message)
      Issue.new(field:, code:, message:)
    end

    def blank_string?(value)
      !value.is_a?(String) || value.empty?
    end
  end
end
