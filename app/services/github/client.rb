require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module Github
  class Client
    include Errors

    EVENTS_URL = "https://api.github.com/events"
    USER_AGENT = "strongmind-github-events"
    ACCEPT = "application/vnd.github+json"
    TRANSIENT_STATUSES = [500, 502, 503, 504].freeze
    NETWORK_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      EOFError,
      IOError,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ETIMEDOUT
    ].freeze
    HEADER_NAMES = {
      rate_limit_limit: "X-RateLimit-Limit",
      rate_limit_remaining: "X-RateLimit-Remaining",
      rate_limit_reset: "X-RateLimit-Reset",
      retry_after: "Retry-After",
      etag: "ETag",
      last_modified: "Last-Modified"
    }.freeze

    Response = Data.define(:data, :headers, :status)

    def initialize(
      open_timeout: 5,
      read_timeout: 10,
      max_attempts: 3,
      max_retry_delay: 60,
      sleeper: ->(seconds) { Kernel.sleep(seconds) },
      clock: -> { Time.now }
    )
      raise ArgumentError, "max_attempts must be at least 1" if max_attempts < 1

      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_attempts = max_attempts
      @max_retry_delay = max_retry_delay.to_f
      @sleeper = sleeper
      @clock = clock
    end

    def fetch_events
      get(EVENTS_URL, expected_type: Array)
    end

    def fetch_resource(url)
      get(url, expected_type: Hash)
    end

    private

    attr_reader :open_timeout, :read_timeout, :max_attempts, :max_retry_delay, :sleeper, :clock

    def get(url, expected_type:)
      uri = validated_uri(url)
      attempts = 0

      begin
        attempts += 1
        response = perform_get(uri)
        build_response(response, expected_type:)
      rescue TransientHttpFailure, RateLimited => error
        delay = delay_for(error, attempts)
        raise error if error.is_a?(RateLimited) && delay > max_retry_delay
        raise RetryExhausted.new(attempts:, last_error: error), cause: error if attempts >= max_attempts

        sleeper.call(delay)
        retry
      end
    end

    def validated_uri(url)
      uri = URI.parse(url.to_s)
      valid = uri.is_a?(URI::HTTPS) &&
        uri.host == "api.github.com" &&
        uri.port == 443 &&
        uri.userinfo.nil?

      raise InvalidUrl, url unless valid

      uri
    rescue URI::InvalidURIError
      raise InvalidUrl, url
    end

    def perform_get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout

      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = ACCEPT

      http.request(request)
    rescue *NETWORK_ERRORS => error
      raise TransientHttpFailure, "GitHub network failure: #{error.class}", cause: error
    end

    def build_response(response, expected_type:)
      status = response.code.to_i
      headers = response_headers(response)

      if status.between?(200, 299)
        data = parse_json(response.body, status:, headers:)
        unless data.is_a?(expected_type)
          raise UnexpectedResponse.new(expected: expected_type.name, actual: data.class.name)
        end

        return Response.new(data:, headers:, status:)
      end

      if status == 429 || rate_limited_403?(status, headers, response.body)
        raise RateLimited.new(
          github_message(response.body) || "GitHub rate limit exceeded",
          retry_delay: rate_limit_delay(headers),
          status:,
          headers:,
          body: response.body
        )
      end

      error_class = TRANSIENT_STATUSES.include?(status) ? TransientHttpFailure : PermanentHttpFailure
      raise error_class.new(
        github_message(response.body) || "GitHub request failed with HTTP #{status}",
        status:,
        headers:,
        body: response.body
      )
    end

    def parse_json(body, status:, headers:)
      JSON.parse(body)
    rescue JSON::ParserError => error
      raise MalformedJson.new(
        "GitHub returned malformed JSON",
        status:,
        headers:,
        body:
      ), cause: error
    end

    def response_headers(response)
      HEADER_NAMES.to_h { |key, header| [key, response[header]] }
    end

    def rate_limited_403?(status, headers, body)
      return false unless status == 403

      headers[:rate_limit_remaining] == "0" ||
        value_present?(headers[:retry_after]) ||
        github_message(body)&.downcase&.include?("rate limit")
    end

    def github_message(body)
      parsed = JSON.parse(body)
      parsed["message"] if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def delay_for(error, attempts)
      return error.retry_delay || exponential_delay(attempts) if error.is_a?(RateLimited)

      exponential_delay(attempts)
    end

    def exponential_delay(attempts)
      [2**(attempts - 1), max_retry_delay].min
    end

    def rate_limit_delay(headers)
      retry_after_delay(headers[:retry_after]) ||
        reset_delay(headers[:rate_limit_reset])
    end

    def retry_after_delay(value)
      return unless value_present?(value)

      [Float(value), 0].max
    rescue ArgumentError, TypeError
      [Time.httpdate(value) - clock.call, 0].max
    rescue Date::Error
      nil
    end

    def reset_delay(value)
      return unless value_present?(value)

      [Integer(value) - clock.call.to_i, 0].max
    rescue ArgumentError, TypeError
      nil
    end

    def value_present?(value)
      !value.nil? && !value.empty?
    end
  end
end
