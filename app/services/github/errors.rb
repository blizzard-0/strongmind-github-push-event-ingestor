module Github
  module Errors
    class Error < StandardError
      attr_reader :status, :headers, :body

      def initialize(message, status: nil, headers: {}, body: nil)
        super(message)
        @status = status
        @headers = headers
        @body = body
      end
    end

    class InvalidUrl < Error
      attr_reader :url

      def initialize(url)
        super("GitHub URL must use HTTPS on api.github.com")
        @url = url
      end
    end

    class MalformedJson < Error; end

    class UnexpectedResponse < Error
      attr_reader :expected, :actual

      def initialize(expected:, actual:)
        super("Expected GitHub response to be a #{expected}, got #{actual}")
        @expected = expected
        @actual = actual
      end
    end

    class PermanentHttpFailure < Error; end
    class TransientHttpFailure < Error; end

    class RateLimited < Error
      attr_reader :retry_delay

      def initialize(message, retry_delay:, **attributes)
        super(message, **attributes)
        @retry_delay = retry_delay
      end
    end

    class RetryExhausted < Error
      attr_reader :attempts, :last_error

      def initialize(attempts:, last_error:)
        super(
          "GitHub request failed after #{attempts} attempts: #{last_error.message}",
          status: last_error.status,
          headers: last_error.headers,
          body: last_error.body
        )
        @attempts = attempts
        @last_error = last_error
      end
    end
  end
end
