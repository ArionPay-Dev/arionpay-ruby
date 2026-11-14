# frozen_string_literal: true

# Runs against a real ArionPay server. Skipped unless ARIONPAY_IT_BASE_URL is set:
#
#   ARIONPAY_IT_BASE_URL=http://127.0.0.1:18090 ARIONPAY_IT_API_KEY=pk_... ARIONPAY_IT_API_SECRET=sk_... \
#   ARIONPAY_IT_WEBHOOK_SECRET=whsec_... ruby -Ilib -Itest test/test_integration.rb
#
# The store's webhook address must be http://127.0.0.1:<ARIONPAY_IT_HOOK_PORT, default 18099>/hook (a dev server that
# allows private webhook addresses).

require "minitest/autorun"
require "socket"
require "arionpay"

class IntegrationTest < Minitest::Test
  # A tiny HTTP listener: reads one request per connection and answers 200 (verified) or 401.
  def start_hook(port, client)
    @received = Queue.new
    @all = []
    @refused = []
    server = TCPServer.new("127.0.0.1", port)
    thread = Thread.new do
      loop do
        sock = server.accept
        begin
          sock.gets # request line
          headers = {}
          while (line = sock.gets) && line != "\r\n"
            k, v = line.split(":", 2)
            headers[k.strip.downcase] = v.to_s.strip
          end
          raw = sock.read(headers["content-length"].to_i).to_s
          begin
            ev = client.verify_webhook(raw, headers["arionpay-signature"])
            @all << ev
            @received << ev
            sock.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          rescue ArionPay::SignatureError => e
            @refused << e.message
            sock.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          end
        ensure
          sock.close
        end
      end
    rescue IOError
      nil
    end
    [server, thread]
  end

  def wait_for(what, seconds = 60)
    deadline = Time.now + seconds
    loop do
      found = @all.find { |e| yield(e) }
      return found if found

      flunk "#{what} not received; got #{@all.map { |e| e["type"] }}, refused #{@refused}" if Time.now > deadline
      sleep 0.3
    end
  end

  def test_full_sandbox_payment_with_real_webhook
    base = ENV["ARIONPAY_IT_BASE_URL"]
    skip "set ARIONPAY_IT_BASE_URL to run against a real server" if base.to_s.empty?
    port = Integer(ENV.fetch("ARIONPAY_IT_HOOK_PORT", "18099"))
    hook = "http://127.0.0.1:#{port}/hook"
    ap = ArionPay::Client.new(api_key: ENV["ARIONPAY_IT_API_KEY"], api_secret: ENV["ARIONPAY_IT_API_SECRET"],
                              webhook_secret: ENV["ARIONPAY_IT_WEBHOOK_SECRET"], base_url: base, app_info: "ruby-integration-test")
    server, thread = start_hook(port, ap)
    begin
      assert(ap.currencies.any? { |c| c["symbol"] == "USDT_TRC20" })
      refute_empty ap.rates("EUR")

      order_id = "rb-it-#{(Time.now.to_f * 1000).to_i}"
      inv = ap.create_invoice(amount: "7.25", currency: "USD", order_id: order_id, asset: "USDT_TRC20", test: true,
                              metadata: { "cart" => "rb", "n" => 3 }, callback_url: hook)
      assert_match(/\A[0-9a-f]{24}\z/, inv["id"])
      assert inv["invoiceUrl"].end_with?("/pay/#{inv["id"]}")
      assert_equal order_id, inv["orderId"]

      key = "rb-key-#{(Time.now.to_f * 1000).to_i}"
      a = ap.create_invoice(amount: "5", order_id: "#{order_id}-b", idempotency_key: key, test: true)
      b = ap.create_invoice(amount: "5", order_id: "#{order_id}-b", idempotency_key: key, test: true)
      assert_equal a["id"], b["id"]
      e = assert_raises(ArionPay::APIError) { ap.create_invoice(amount: "6", order_id: "#{order_id}-b", idempotency_key: key, test: true) }
      assert_equal "idempotency_key_reused", e.code

      read = ap.get_invoice(inv["id"])
      assert_equal "new", read["status"]
      assert_equal({ "cart" => "rb", "n" => 3 }, read["metadata"])
      assert_equal true, read["test"]

      ap.simulate_payment(inv["id"], "detected")
      pending = wait_for("invoice.pending") { |ev| ev["type"] == "invoice.pending" && ev["data"]["invoice"]["id"] == inv["id"] }
      assert_equal "pending", pending["data"]["invoice"]["status"]
      ap.simulate_payment(inv["id"], "confirm")
      paid = wait_for("invoice.paid") { |ev| ev["type"] == "invoice.paid" && ev["data"]["invoice"]["id"] == inv["id"] }
      pi = paid["data"]["invoice"]
      assert_equal order_id, pi["orderId"]
      assert_equal true, pi["test"]
      refute ArionPay.test_event?(paid)
      assert ArionPay.order_matches?(pi, "7.25", "USD")
      assert_equal "USDT_TRC20", pi["asset"]
      assert_equal "rb", pi["metadata"]["cart"]

      read = ap.get_invoice(inv["id"])
      assert_equal "paid", read["status"]
      assert_equal 7.25, read["amountFiat"]
      assert ArionPay.order_matches?(read, "7.25", "USD")
      refute_equal "0", read["paidCrypto"]

      under = ap.create_invoice(amount: "20", order_id: "#{order_id}-u", asset: "USDT_TRC20", test: true, callback_url: hook)
      ap.simulate_payment(under["id"], "underpaid_1pct")
      up = wait_for("tolerance invoice.paid") { |ev| ev["type"] == "invoice.paid" && ev["data"]["invoice"]["id"] == under["id"] }
      assert_equal true, up["data"]["invoice"]["underpaidWithinTolerance"]
      assert ArionPay.order_matches?(up["data"]["invoice"], "20", "USD")

      t = ap.send_test_webhook("invoice.expired")
      assert_equal true, t["delivered"], t.inspect
      assert ArionPay.test_event?(wait_for("test event") { |ev| ev["id"] == t["eventId"] })

      assert_equal 404, assert_raises(ArionPay::APIError) { ap.get_invoice("0" * 24) }.status
      wrong = ArionPay::Client.new(api_key: ENV["ARIONPAY_IT_API_KEY"], api_secret: "sk_wrong", base_url: base)
      assert_equal 401, assert_raises(ArionPay::APIError) { wrong.get_invoice(inv["id"]) }.status
      assert_equal [], @refused
      puts "\ninvoice #{inv["id"]} paid, #{@all.size} signed webhooks verified"
    ensure
      server.close
      thread.kill
    end
  end
end
