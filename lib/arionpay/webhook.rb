# frozen_string_literal: true

require "json"
require "openssl"

module ArionPay
  # Webhooks signed more than this many seconds ago (or ahead) are refused. ArionPay signs again on every retry.
  DEFAULT_TOLERANCE_SEC = 300

  EVENT_TYPES = %w[invoice.pending invoice.partial invoice.paid invoice.expired invoice.needs_review].freeze

  module_function

  # The x-signature of one API request:
  # POST: hex HMAC-SHA256(secret, "<ts>.<raw body>"), GET: hex HMAC-SHA256(secret, "<ts>.GET <path and query>").
  def sign_request(secret_key, timestamp, method, path_and_query, raw_body = "")
    data = if method.to_s.casecmp?("GET")
             "#{timestamp.to_i}.GET #{path_and_query}"
           else
             "#{timestamp.to_i}.".b + raw_body.to_s.b
           end
    OpenSSL::HMAC.hexdigest("SHA256", secret_key.to_s, data)
  end

  # Reads "t=<unix seconds>,v1=<hex>". Returns [t, v1] or nil when the header is malformed.
  def parse_signature_header(header)
    return nil unless header.is_a?(String)

    values = {}
    header.split(",").each do |part|
      key, value = part.split("=", 2)
      values[key.strip] = value.strip if key && value
    end
    t = values["t"]
    v1 = values["v1"]
    return nil unless t&.match?(/\A[0-9]{1,12}\z/) && v1&.match?(/\A[0-9a-fA-F]{64}\z/)

    [t.to_i, v1.downcase]
  end

  # True when header is a valid, fresh signature of exactly raw_body. Never raises.
  def valid_signature?(raw_body, header, webhook_secret, tolerance_sec: DEFAULT_TOLERANCE_SEC, now: Time.now.to_i)
    return false unless raw_body.is_a?(String) && webhook_secret.is_a?(String) && !webhook_secret.empty?

    parsed = parse_signature_header(header)
    return false unless parsed

    t, v1 = parsed
    return false if (now.to_i - t).abs > tolerance_sec

    expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, "#{t}.".b + raw_body.b)
    OpenSSL.fixed_length_secure_compare(expected, v1)
  end

  # Checks a webhook and returns the event (a Hash with string keys, as ArionPay sent it), or raises SignatureError.
  #
  # raw_body must be the exact bytes ArionPay sent: request.raw_post (Rails), request.body.read (Sinatra/Rack),
  # never parsed and re-encoded JSON.
  def verify_webhook(raw_body, signature_header, webhook_secret, tolerance_sec: DEFAULT_TOLERANCE_SEC, now: Time.now.to_i)
    if webhook_secret.nil? || webhook_secret.to_s.empty?
      raise SignatureError, "The webhook secret is empty. Copy it from the Webhooks page of your ArionPay dashboard (it starts with whsec_)."
    end
    unless raw_body.is_a?(String)
      raise SignatureError, "Pass the raw request body (a String: request.raw_post in Rails, request.body.read in Sinatra), not parsed JSON."
    end
    raise SignatureError, "Missing or malformed ArionPay-Signature header." unless parse_signature_header(signature_header)
    unless valid_signature?(raw_body, signature_header, webhook_secret.to_s, tolerance_sec: tolerance_sec, now: now)
      raise SignatureError, "Invalid webhook signature or stale timestamp. Check the webhook secret and your server clock."
    end

    text = raw_body.dup.force_encoding(Encoding::UTF_8)
    raise SignatureError, "The webhook body is not JSON." unless text.valid_encoding?

    begin
      event = JSON.parse(text)
    rescue JSON::ParserError
      raise SignatureError, "The webhook body is not JSON."
    end
    valid = event.is_a?(Hash) && event["id"].is_a?(String) && !event["id"].empty? &&
            event["type"].is_a?(String) && !event["type"].empty? &&
            event["data"].is_a?(Hash) && event["data"]["invoice"].is_a?(Hash)
    raise SignatureError, "The webhook body is not an ArionPay event." unless valid

    event
  end

  # True for events made by "Send test webhook": a made-up invoice that must never change an order.
  def test_event?(event)
    return false unless event.is_a?(Hash)

    invoice = event.dig("data", "invoice")
    event["test"] == true || event["id"].to_s.start_with?("evt_test_") ||
      (invoice.is_a?(Hash) && invoice["id"].to_s.start_with?("inv_test_"))
  end

  # True when the invoice price is exactly this order total (to the cent) in this currency: the check to make before
  # you deliver. Crypto amounts never need comparing: ArionPay decides whether an invoice is paid.
  def order_matches?(invoice, order_total, currency)
    return false unless invoice.is_a?(Hash)

    paid = fiat(invoice["amountFiat"])
    !paid.nil? && paid == fiat(order_total) && invoice["currency"].to_s.casecmp?(currency.to_s)
  end

  # "49.90" for 49.9, "49.9" or "49.90"; nil when it is not a number.
  def fiat(value)
    return nil if value.nil? || value == true || value == false

    f = Float(value.to_s)
    f.finite? ? format("%.2f", f) : nil
  rescue ArgumentError, TypeError
    nil
  end
end
