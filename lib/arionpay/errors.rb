# frozen_string_literal: true

module ArionPay
  # Base class of every error this library raises (bad arguments raise ArgumentError).
  class Error < StandardError; end

  # ArionPay answered with an error, or could not be reached (status 0).
  class APIError < Error
    # HTTP status, 0 when ArionPay could not be reached
    attr_reader :status
    # ArionPay error code, e.g. "idempotency_key_reused", "rate_limited", "unknown_asset" ("" when none)
    attr_reader :code
    # decoded error body ("retryAfterSec" added from a Retry-After header)
    attr_reader :body

    def initialize(message, status: 0, code: "", body: {})
      super(message)
      @status = status
      @code = code
      @body = body
    end
  end

  # A webhook must not be trusted: bad or stale signature, wrong secret, or not an ArionPay event.
  class SignatureError < Error; end
end
