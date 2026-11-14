# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "openssl"
require "arionpay"

SECRET = "whsec_unit_0001"
EVENT = {
  "id" => "evt_abc", "type" => "invoice.paid", "created" => 1, "livemode" => true,
  "data" => { "invoice" => { "id" => "6af75d7ce83f10cb386f0981", "status" => "paid", "amountFiat" => 49.9, "currency" => "USD" } }
}.freeze

def h(key, data)
  OpenSSL::HMAC.hexdigest("SHA256", key, data)
end

def signed(body, t = Time.now.to_i, secret = SECRET)
  "t=#{t},v1=#{h(secret, "#{t}.".b + body.b)}"
end

# Answers each request with the next answer; an Exception answer is raised (a network error).
class FakeTransport
  attr_reader :calls

  def initialize(*answers)
    @answers = answers
    @calls = []
  end

  def call(method, url, headers, body, _timeout)
    @calls << { method: method, url: url, headers: headers.dup, body: body }
    a = @answers.shift or raise "unexpected request #{method} #{url}"
    raise a if a.is_a?(Exception)

    status, payload, resp_headers = a
    [status, resp_headers || {}, payload.is_a?(String) ? payload : JSON.generate(payload)]
  end
end

class SignatureTest < Minitest::Test
  def test_request_signatures_match_backend
    assert_equal h("sk_x", '1700000000.{"a":1}'), ArionPay.sign_request("sk_x", 1_700_000_000, "POST", "/api/v1/invoices", '{"a":1}')
    assert_equal h("sk_x", "1700000000.GET /api/v1/invoices/abc?x=1"), ArionPay.sign_request("sk_x", 1_700_000_000, "get", "/api/v1/invoices/abc?x=1", "ignored")
  end

  def test_header_parsing
    v1 = "a" * 64
    assert_equal [123, v1], ArionPay.parse_signature_header("t=123,v1=#{v1}")
    assert_equal [5, v1], ArionPay.parse_signature_header(" v1=#{v1.upcase} , t=5 ")
    ["", nil, "t=1", "v1=#{v1}", "t=x,v1=#{v1}", "t=1,v1=zz", "t=1,v1=#{v1}0", "t=-1,v1=#{v1}", 42].each do |bad|
      assert_nil ArionPay.parse_signature_header(bad), bad.inspect
    end
  end

  def test_valid
    body = JSON.generate(EVENT)
    ev = ArionPay.verify_webhook(body, signed(body), SECRET)
    assert_equal "evt_abc", ev["id"]
    assert_equal "paid", ev["data"]["invoice"]["status"]
    assert ArionPay.valid_signature?(body.b, signed(body), SECRET)
    refute ArionPay.test_event?(ev)
    assert ArionPay.order_matches?(ev["data"]["invoice"], "49.90", "usd")
    refute ArionPay.order_matches?(ev["data"]["invoice"], "49.91", "USD")
    refute ArionPay.order_matches?(ev["data"]["invoice"], 49.9, "EUR")
  end

  def test_non_ascii_and_binary_body
    ev = JSON.parse(JSON.generate(EVENT))
    ev["data"]["invoice"]["description"] = "Café ☕ – 東京"
    body = JSON.generate(ev).b # Rack bodies are binary strings
    assert_equal "Café ☕ – 東京", ArionPay.verify_webhook(body, signed(body), SECRET)["data"]["invoice"]["description"]
  end

  def test_failures
    body = JSON.generate(EVENT)
    hdr = signed(body)
    assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body.sub("paid", "PAID"), hdr, SECRET) }
    assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(JSON.pretty_generate(EVENT), hdr, SECRET) }
    assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, hdr, "whsec_other") }
    assert_match(/empty/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, hdr, "") }.message)
    assert_match(/empty/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, hdr, nil) }.message)
    old = Time.now.to_i - 301
    assert_match(/stale/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, signed(body, old), SECRET) }.message)
    assert_match(/stale/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, signed(body, old + 602), SECRET) }.message)
    assert ArionPay.valid_signature?(body, signed(body, old), SECRET, tolerance_sec: 600)
    assert_match(/raw request body/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(JSON.parse(body), hdr, SECRET) }.message)
    assert_match(/Missing or malformed/, assert_raises(ArionPay::SignatureError) { ArionPay.verify_webhook(body, nil, SECRET) }.message)
    refute ArionPay.valid_signature?({ "x" => 1 }, hdr, SECRET)
    refute ArionPay.valid_signature?(body, hdr, "")
  end

  def test_signed_but_not_event
    ["not json", "{}", "[]", '{"id":"","type":"invoice.paid","data":{"invoice":{}}}', '{"id":"evt_1","type":"invoice.paid"}',
     '{"id":"evt_1","type":"invoice.paid","data":{"invoice":null}}', "\xff\xfe".b, '{"id":5,"type":"invoice.paid","data":{"invoice":{}}}'].each do |body|
      assert_raises(ArionPay::SignatureError, body.inspect) { ArionPay.verify_webhook(body, signed(body), SECRET) }
    end
  end

  def test_test_events
    assert ArionPay.test_event?(EVENT.merge("test" => true))
    assert ArionPay.test_event?(EVENT.merge("id" => "evt_test_1"))
    assert ArionPay.test_event?(EVENT.merge("data" => { "invoice" => { "id" => "inv_test_x" } }))
    refute ArionPay.test_event?(EVENT)
    refute ArionPay.test_event?(nil)
  end

  def test_fiat
    { 49.9 => "49.90", "10" => "10.00", "1e2" => "100.00", "0.005" => "0.01" }.each { |i, o| assert_equal o, ArionPay.fiat(i) }
    [nil, "", "abc", true, "NaN", "Infinity"].each { |bad| assert_nil ArionPay.fiat(bad), bad.inspect }
    refute ArionPay.order_matches?({ "amountFiat" => nil, "currency" => "USD" }, "abc", "USD")
  end
end

class ClientTest < Minitest::Test
  def client(transport, **kw)
    @waits = []
    ts = 1_700_000_000
    ArionPay::Client.new(api_key: "pk_unit_000001", api_secret: "sk_unit", base_url: "https://example.test/", transport: transport,
                         sleeper: ->(s) { @waits << s }, clock: -> { ts += 1 }, **kw)
  end

  def test_constructor_checks
    assert_match(/pk_/, assert_raises(ArgumentError) { ArionPay::Client.new(api_key: "nope", api_secret: "s") }.message)
    assert_match(/api_secret/, assert_raises(ArgumentError) { ArionPay::Client.new(api_key: "pk_abcdefgh", api_secret: "") }.message)
    assert_match(/http/, assert_raises(ArgumentError) { ArionPay::Client.new(api_key: "pk_abcdefgh", api_secret: "s", base_url: "ftp://x") }.message)
    assert_match(/http/, assert_raises(ArgumentError) { ArionPay::Client.new(api_key: "pk_abcdefgh", api_secret: "s", base_url: "not a url") }.message)
    c = ArionPay::Client.new(api_key: "pk_abcdefgh", api_secret: "sk_hidden", app_info: "myshop/2.1")
    assert_match(%r{\Aarionpay-ruby/#{ArionPay::VERSION} ruby/\S+ myshop/2\.1\z}, c.user_agent)
    refute_includes c.inspect, "sk_hidden"
  end

  def test_create_signs_exact_body
    t = FakeTransport.new([201, { "status" => "success", "id" => "a" * 24, "invoice_url" => "https://x/pay/1",
                                  "data" => { "id" => "a" * 24, "invoice_url" => "https://x/pay/1", "amount_fiat" => 9.5, "currency" => "EUR", "status" => "new", "order_id" => "7" } }])
    inv = client(t).create_invoice(amount: "9.50", currency: "EUR", order_id: 7, metadata: { "name" => "Zoë <b>" }, test: true)
    assert_equal "https://x/pay/1", inv["invoiceUrl"]
    assert_equal 9.5, inv["amountFiat"]
    assert_equal "7", inv["orderId"]
    c = t.calls[0]
    assert_equal "https://example.test:443/api/v1/invoices", c[:url]
    body = JSON.parse(c[:body])
    assert_equal "9.50", body["amount"]
    assert_equal "7", body["orderId"]
    assert_equal true, body["test"]
    assert_equal "Zoë <b>", body["metadata"]["name"]
    refute body.key?("description")
    assert body["idempotencyKey"].start_with?("sdk_")
    assert_equal h("sk_unit", "#{c[:headers]["x-timestamp"]}.".b + c[:body].b), c[:headers]["x-signature"]
    assert_equal "pk_unit_000001", c[:headers]["x-api-key"]
  end

  def test_get_signed_over_path_with_base_path
    t = FakeTransport.new([200, { "invoiceId" => "b" * 24, "status" => "PAID", "amountFiat" => 1, "currency" => "USD", "test" => true,
                                  "settledCurrency" => "USDT_TRC20", "amountReceived" => "1.000000", "metadata" => { "k" => "v" } }])
    inv = client(t, base_url: "https://example.test/gw/").get_invoice("b" * 24)
    assert_equal "paid", inv["status"]
    assert_equal true, inv["test"]
    assert_equal "USDT_TRC20", inv["asset"]
    assert_equal "0", inv["confirmedCrypto"]
    assert_equal({ "k" => "v" }, inv["metadata"])
    assert ArionPay.order_matches?(inv, "1.00", "USD")
    c = t.calls[0]
    assert_equal "https://example.test:443/gw/api/v1/invoices/#{"b" * 24}", c[:url]
    assert_equal h("sk_unit", "#{c[:headers]["x-timestamp"]}.GET /gw/api/v1/invoices/#{"b" * 24}"), c[:headers]["x-signature"]
  end

  def test_replay_resigned_once
    used = [401, { "error" => "This signed request was already used. Sign each request with a fresh timestamp." }]
    t = FakeTransport.new(used, [200, { "invoiceId" => "c" * 24, "status" => "NEW" }])
    assert_equal "new", client(t).get_invoice("c" * 24)["status"]
    assert_equal 2, t.calls.size
    refute_equal t.calls[0][:headers]["x-timestamp"], t.calls[1][:headers]["x-timestamp"]
    assert_equal [1.1], @waits
    t2 = FakeTransport.new(used, used)
    assert_equal 401, assert_raises(ArionPay::APIError) { client(t2).get_invoice("c" * 24) }.status
    assert_equal 2, t2.calls.size
  end

  def test_create_retry_keeps_idempotency_key
    t = FakeTransport.new(Errno::ECONNREFUSED.new, [503, { "error" => "busy" }], [201, { "id" => "d" * 24, "invoice_url" => "u", "data" => {} }])
    inv = client(t).create_invoice(amount: 1)
    assert_equal "new", inv["status"]
    assert_equal "USD", inv["currency"]
    assert_equal 3, t.calls.size
    assert_equal t.calls[0][:body], t.calls[2][:body]
    assert_equal [0.5, 1.5], @waits
  end

  def test_rate_limit
    t = FakeTransport.new([429, { "error" => "slow down", "code" => "rate_limited" }, { "Retry-After" => "2" }], [200, { "invoiceId" => "e" * 24, "status" => "NEW" }])
    client(t).get_invoice("e" * 24)
    assert_equal [2], @waits
    t2 = FakeTransport.new([429, { "error" => "slow down", "code" => "rate_limited", "retryAfterSec" => 60 }])
    e = assert_raises(ArionPay::APIError) { client(t2).get_invoice("e" * 24) }
    assert_equal [429, "rate_limited", 1], [e.status, e.code, t2.calls.size]
  end

  def test_no_retry_for_simulate_and_codes
    t = FakeTransport.new([503, { "error" => "busy" }])
    assert_equal 503, assert_raises(ArionPay::APIError) { client(t).simulate_payment("e" * 24, "exact") }.status
    assert_equal 1, t.calls.size
    t = FakeTransport.new([409, { "error" => "This Idempotency-Key was already used", "code" => "idempotency_key_reused" }])
    e = assert_raises(ArionPay::APIError) { client(t).create_invoice(amount: "1", idempotency_key: "k") }
    assert_equal [409, "idempotency_key_reused"], [e.status, e.code]
    assert_equal 1, t.calls.size
    assert_includes e.message, "(409)"
    refute_includes e.message, "sk_unit"
  end

  def test_unreachable
    t = FakeTransport.new(SocketError.new("getaddrinfo failed"), Net::OpenTimeout.new("timed out"))
    e = assert_raises(ArionPay::APIError) { client(t, max_attempts: 2).get_invoice("f" * 24) }
    assert_equal 0, e.status
    assert_equal "network_error", e.code
    assert_includes e.message, "Could not reach"
    assert_equal 2, t.calls.size
  end

  def test_non_json_error_page
    t = FakeTransport.new([502, "<html>Bad gateway</html>"], [502, "<html>Bad gateway</html>"], [502, ""])
    e = assert_raises(ArionPay::APIError) { client(t).get_invoice("f" * 24) }
    assert_equal [502, "ArionPay API error (502): HTTP 502"], [e.status, e.message]
  end

  def test_bad_input_never_reaches_network
    t = FakeTransport.new
    c = client(t)
    assert_raises(ArgumentError) { c.get_invoice("../admin") }
    assert_raises(ArgumentError) { c.get_invoice(nil) }
    assert_raises(ArgumentError) { c.simulate_payment("a" * 24, "free_money") }
    assert_raises(ArgumentError) { c.create_invoice(amount: nil) }
    assert_raises(ArgumentError) { c.create_invoice(amount: " ") }
    assert_empty t.calls
  end

  def test_reads_and_test_webhook
    t = FakeTransport.new([200, { "currencies" => [{ "symbol" => "USDT_TRC20" }] }], [200, { "currency" => "EUR" }],
                          [200, { "delivered" => true, "eventId" => "evt_test_1" }])
    c = client(t)
    assert_equal "USDT_TRC20", c.currencies[0]["symbol"]
    assert_nil t.calls[0][:headers]["x-signature"]
    assert_equal "EUR", c.rates("EUR")["currency"]
    assert t.calls[1][:url].end_with?("/api/v1/rates?currency=EUR")
    assert_equal true, c.send_test_webhook["delivered"]
    assert_equal "invoice.paid", JSON.parse(t.calls[2][:body])["eventType"]
  end

  def test_client_verify_webhook
    c = ArionPay::Client.new(api_key: "pk_abcdefgh", api_secret: "s", webhook_secret: SECRET)
    body = JSON.generate(EVENT)
    assert_equal "invoice.paid", c.verify_webhook(body, signed(body))["type"]
  end
end
