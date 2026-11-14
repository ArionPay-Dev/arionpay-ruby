# frozen_string_literal: true

# A minimal shop as a plain Rack app (Rails, Sinatra and Hanami run on Rack too):
# /pay/<order> sends the customer to ArionPay, /arionpay/webhook marks the order paid.
#
#   gem install arionpay rackup webrick
#   ARIONPAY_API_KEY=pk_... ARIONPAY_API_SECRET=sk_... ARIONPAY_WEBHOOK_SECRET=whsec_... \
#   PUBLIC_URL=https://shop.example.com rackup examples/config.ru -p 8080
require "arionpay"
require "json"

CLIENT = ArionPay::Client.new(
  api_key: ENV.fetch("ARIONPAY_API_KEY"),
  api_secret: ENV.fetch("ARIONPAY_API_SECRET"),
  webhook_secret: ENV.fetch("ARIONPAY_WEBHOOK_SECRET"),
  base_url: ENV.fetch("ARIONPAY_BASE_URL", ArionPay::DEFAULT_BASE_URL),
  app_info: "example-shop/1.0"
)
PUBLIC_URL = ENV.fetch("PUBLIC_URL").chomp("/")
TEST_MODE = ENV["ARIONPAY_LIVE"] != "1"

ORDERS = { "2001" => { total: "49.90", currency: "USD", paid: false } } # use your database
PROCESSED = {} # event ids already handled
LOCK = Mutex.new

def text(status, body)
  [status, { "content-type" => "text/plain" }, [body]]
end

app = lambda do |env|
  req = Rack::Request.new(env)
  if req.get? && req.path =~ %r{\A/pay/([\w-]+)\z}
    id = Regexp.last_match(1)
    order = LOCK.synchronize { ORDERS[id] }
    next text(404, "No such order") unless order

    begin
      inv = CLIENT.create_invoice(
        amount: order[:total], currency: order[:currency], order_id: id,
        success_url: "#{PUBLIC_URL}/thanks/#{id}", cancel_url: "#{PUBLIC_URL}/cart",
        callback_url: "#{PUBLIC_URL}/arionpay/webhook",
        idempotency_key: "order-#{id}-#{order[:total]}#{order[:currency]}", # one invoice per order total
        test: TEST_MODE
      )
    rescue ArionPay::APIError => e
      warn "ArionPay: #{e.message}"
      next text(502, "The crypto payment could not be started. Please try again in a minute.")
    end
    next [303, { "location" => inv["invoiceUrl"] }, []]
  end

  if req.post? && req.path == "/arionpay/webhook"
    raw = req.body.read # the exact bytes: check before parsing
    begin
      event = CLIENT.verify_webhook(raw, req.get_header("HTTP_ARIONPAY_SIGNATURE"))
    rescue ArionPay::SignatureError
      next text(401, "invalid signature")
    end
    next text(200, "ok") if ArionPay.test_event?(event) # "Send test webhook": a made-up invoice

    invoice = event["data"]["invoice"]
    result = LOCK.synchronize do
      if PROCESSED[event["id"]]
        200
      elsif invoice["test"] != TEST_MODE
        409 # a test invoice in the live shop (or the other way round)
      else
        order = ORDERS[invoice["orderId"].to_s]
        if event["type"] == "invoice.paid" && order && !order[:paid] && ArionPay.order_matches?(invoice, order[:total], order[:currency])
          order[:paid] = true # deliver here
          warn "order #{invoice["orderId"]} paid with #{invoice["paidCrypto"]} #{invoice["asset"]} (invoice #{invoice["id"]})"
        end
        PROCESSED[event["id"]] = true
        200
      end
    end
    next text(result, result == 200 ? "ok" : "test/live mismatch")
  end

  text(404, "Not found")
end

run app
