# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module ArionPay
  DEFAULT_BASE_URL = "https://merchant.arionpay.com"

  # Scenarios for Client#simulate_payment (test invoices only).
  SCENARIOS = %w[detected confirm exact underpaid_1pct underpaid_5pct overpaid partial_half late].freeze

  # ArionPay merchant API client. Safe to share between threads.
  #
  #   client = ArionPay::Client.new(api_key: ENV["ARIONPAY_API_KEY"], api_secret: ENV["ARIONPAY_API_SECRET"])
  #   invoice = client.create_invoice(amount: "49.90", currency: "USD", order_id: "1001")
  #   # send the customer to invoice["invoiceUrl"]
  #
  # Invoices are Hashes with string keys and the same field names as the webhook's data.invoice ("id", "status",
  # "orderId", "amountFiat", ...), so one method can handle a webhook and a read.
  class Client
    PK_PATTERN = /\Apk_[A-Za-z0-9_-]{8,64}\z/.freeze
    ID_PATTERN = /\A[0-9a-fA-F]{24}\z/.freeze
    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError].freeze

    # transport (for tests): ->(method, url, headers, body, timeout) { [status, headers_hash, body_string] }
    def initialize(api_key:, api_secret:, webhook_secret: "", base_url: DEFAULT_BASE_URL, timeout: 20, max_attempts: 3,
                   app_info: nil, transport: nil, sleeper: nil, clock: nil)
      raise ArgumentError, "api_key must be your store API key (it starts with pk_)." unless api_key.is_a?(String) && api_key.match?(PK_PATTERN)
      raise ArgumentError, "api_secret is required (your store API secret, it starts with sk_)." if api_secret.nil? || api_secret.to_s.empty?

      uri = begin
        URI.parse(base_url.to_s)
      rescue URI::InvalidURIError
        nil
      end
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        raise ArgumentError, "base_url must be an http(s) address."
      end

      @api_key = api_key
      @api_secret = api_secret.to_s
      @webhook_secret = webhook_secret.to_s
      @scheme = uri.scheme
      @host = uri.host
      @port = uri.port
      @base_path = uri.path.to_s.sub(%r{/+\z}, "")
      @timeout = timeout.to_f
      @max_attempts = max_attempts.to_i.clamp(1, 5)
      @transport = transport || method(:net_http_transport)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @clock = clock || -> { Time.now.to_i }
      @user_agent = "arionpay-ruby/#{VERSION} ruby/#{RUBY_VERSION}#{app_info ? " #{app_info}" : ""}"
    end

    attr_reader :user_agent

    # Creates an invoice. Returns {"id", "invoiceUrl", "status", "amountFiat", "currency", "asset", "address",
    # "amountCrypto", "expiresAt", "orderId", "raw"}. Send the customer to "invoiceUrl".
    #
    # Safe to retry: each call carries an idempotency key (a random one when you pass none), so a repeat after a
    # network error returns the same invoice. Pass your own key (e.g. "order-1001-49.90USD") to be safe across
    # restarts. The customer coming back to success_url does NOT prove payment: wait for the invoice.paid webhook.
    def create_invoice(amount:, currency: "USD", order_id: nil, description: nil, customer_email: nil, success_url: nil,
                       cancel_url: nil, callback_url: nil, asset: nil, allowed_assets: nil, expires_min: nil,
                       metadata: nil, idempotency_key: nil, test: nil)
      raise ArgumentError, "amount is required." if amount.nil? || amount == true || amount == false || amount.to_s.strip.empty?

      fields = {
        "amount" => amount.to_s,
        "currency" => currency,
        "orderId" => order_id&.to_s,
        "description" => description,
        "customerEmail" => customer_email,
        "successUrl" => success_url,
        "cancelUrl" => cancel_url,
        "callbackUrl" => callback_url,
        "asset" => asset,
        "allowedAssets" => allowed_assets,
        "expiresMin" => expires_min,
        "metadata" => metadata,
        "idempotencyKey" => idempotency_key || "sdk_#{SecureRandom.uuid}",
        "test" => test
      }
      r = request("POST", "/api/v1/invoices", fields.compact, retry_safe: true)
      d = r["data"].is_a?(Hash) ? r["data"] : r
      {
        "id" => (d["id"] || r["id"]).to_s,
        "invoiceUrl" => (d["invoice_url"] || r["invoice_url"]).to_s,
        "status" => (d["status"] || "new").to_s,
        "amountFiat" => d["amount_fiat"],
        "currency" => (d["currency"] || currency).to_s,
        "asset" => d["asset"],
        "address" => d["address"],
        "amountCrypto" => d["amount_crypto"],
        "expiresAt" => d["expires_at"],
        "orderId" => d.key?("order_id") ? d["order_id"] : order_id,
        "raw" => r
      }
    end

    # Reads an invoice, signed, straight from ArionPay (webhook field names). Use it to double-check, or to poll.
    def get_invoice(invoice_id)
      check_id(invoice_id)
      ArionPay.normalize_invoice_read(request("GET", "/api/v1/invoices/#{invoice_id}", nil, retry_safe: true))
    end

    # Sandbox: moves a TEST invoice through a payment scenario (see SCENARIOS); webhooks then fire as for a real
    # payment. Create the test invoice with asset: (e.g. "USDT_TRC20") so a coin is chosen.
    def simulate_payment(invoice_id, scenario = "exact")
      check_id(invoice_id)
      raise ArgumentError, "scenario must be one of: #{SCENARIOS.join(", ")}" unless SCENARIOS.include?(scenario)

      request("POST", "/api/v1/invoices/#{invoice_id}/simulate", { "scenario" => scenario }, retry_safe: false)
    end

    # Asks ArionPay to send a signed sample event to your store's webhook address. It never describes a real order.
    def send_test_webhook(event_type = "invoice.paid")
      request("POST", "/api/v1/webhooks/test", { "eventType" => event_type }, retry_safe: false)
    end

    # Coins you can pass as asset: / allowed_assets: ("USDT_TRC20", "BTC", "LTC", ...), with USD rates.
    def currencies
      r = request("GET", "/api/v1/currencies", nil, retry_safe: true, signed: false)
      r["currencies"].is_a?(Array) ? r["currencies"] : []
    end

    # Current coin prices in one fiat currency.
    def rates(currency = "USD")
      request("GET", "/api/v1/rates?currency=#{URI.encode_www_form_component(currency)}", nil, retry_safe: true, signed: false)
    end

    # Checks a webhook with the webhook_secret given to the constructor. See ArionPay.verify_webhook.
    def verify_webhook(raw_body, signature_header, tolerance_sec: DEFAULT_TOLERANCE_SEC)
      ArionPay.verify_webhook(raw_body, signature_header, @webhook_secret, tolerance_sec: tolerance_sec)
    end

    def inspect
      "#<ArionPay::Client #{@scheme}://#{@host}#{@base_path} key=#{@api_key}>" # never shows the secrets
    end

    private

    def check_id(invoice_id)
      return if invoice_id.is_a?(String) && invoice_id.match?(ID_PATTERN)

      raise ArgumentError, "Invoice id must be the 24-character id ArionPay returned."
    end

    def request(method, path, body, retry_safe:, signed: true)
      raw = body.nil? ? nil : JSON.generate(body)
      replay_retry_used = false
      attempt = 0
      begin
        attempt += 1
        send_request(method, path, raw, signed)
      rescue APIError => e
        # Two identical signed requests in the same second have the same signature; only the first is accepted.
        if e.status == 401 && e.message.downcase.include?("already used") && !replay_retry_used
          replay_retry_used = true
          @sleeper.call(1.1)
          retry
        end
        retry_after = Integer(e.body["retryAfterSec"] || 0, exception: false) || 0
        temporary = [0, 502, 503, 504].include?(e.status) || (e.status == 429 && retry_after <= 5)
        raise if !retry_safe || !temporary || attempt >= @max_attempts

        @sleeper.call(e.status == 429 ? [1, retry_after].max : 0.5 * (3**(attempt - 1)))
        retry
      end
    end

    def send_request(method, path, raw, signed)
      path_only, query = path.split("?", 2)
      full_path = @base_path + path_only + (query ? "?#{query}" : "")
      headers = { "Accept" => "application/json", "User-Agent" => @user_agent }
      if signed
        ts = @clock.call
        headers["x-api-key"] = @api_key
        headers["x-timestamp"] = ts.to_s
        headers["x-signature"] = ArionPay.sign_request(@api_secret, ts, method, full_path, raw || "")
      end
      headers["Content-Type"] = "application/json" if raw
      begin
        status, resp_headers, data = @transport.call(method, "#{@scheme}://#{@host}:#{@port}#{full_path}", headers, raw, @timeout)
      rescue *NETWORK_ERRORS => e
        raise APIError.new("Could not reach ArionPay: #{e.message}", status: 0, code: "network_error", body: {})
      end
      obj = begin
        decoded = data.nil? || data.empty? ? {} : JSON.parse(data.dup.force_encoding(Encoding::UTF_8))
        decoded.is_a?(Hash) ? decoded : {}
      rescue JSON::ParserError, EncodingError
        {}
      end
      return obj if status >= 200 && status < 300

      message = [obj["error"], obj["message"]].find { |m| m.is_a?(String) } || "HTTP #{status}"
      err_body = obj.dup
      lower = (resp_headers || {}).each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = Array(v).first }
      retry_after = Integer(lower["retry-after"].to_s, exception: false)
      err_body["retryAfterSec"] = retry_after if retry_after&.positive?
      raise APIError.new("ArionPay API error (#{status}): #{message}", status: status, code: obj["code"].is_a?(String) ? obj["code"] : "", body: err_body)
    end

    def net_http_transport(method, url, headers, body, timeout)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.max_retries = 0 # retries are decided above (a POST must never be repeated blindly)
      req = method == "GET" ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      res = http.start { |h| h.request(req) } # Net::HTTP never follows redirects
      [res.code.to_i, res.each_header.to_h, res.body.to_s]
    end
  end

  module_function

  # Turns the signed read (GET /api/v1/invoices/<id>) into the webhook invoice field names.
  def normalize_invoice_read(r)
    out = {
      "id" => (r["invoiceId"] || r["id"]).to_s,
      "status" => r["status"].to_s.downcase,
      "orderId" => r["orderId"],
      "amountFiat" => r["amountFiat"],
      "currency" => r["currency"].to_s,
      "asset" => r["settledCurrency"].to_s,
      "network" => r["network"].to_s,
      "amountCrypto" => r["amountExpected"].to_s,
      "paidCrypto" => (r["amountReceived"] || "0").to_s,
      "confirmedCrypto" => (r["amountConfirmed"] || "0").to_s,
      "overpaid" => r["overpaid"] == true,
      "underpaidWithinTolerance" => r["underpaidWithinTolerance"] == true,
      "late" => r["late"] == true,
      "needsReview" => r["needsReview"] == true,
      "reviewReason" => r["reviewReason"],
      "manual" => r["manual"] == true,
      "test" => r["test"] == true,
      "transactions" => r["transactions"].is_a?(Array) ? r["transactions"] : [],
      "metadata" => r["metadata"].is_a?(Hash) ? r["metadata"] : {},
      "paidAt" => r["settledAt"],
      "txHash" => r["txHash"],
      "confirmations" => r["confirmations"] || 0,
      "requiredConfirmations" => r["requiredConfirmations"] || 0,
      "raw" => r
    }
    out["paidVia"] = r["paidVia"] if r.key?("paidVia")
    out
  end
end
