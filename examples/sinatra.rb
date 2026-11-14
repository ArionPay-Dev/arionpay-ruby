# frozen_string_literal: true

# Sinatra: a checkout route and the webhook.   ruby examples/sinatra.rb   (gem install arionpay sinatra rackup puma)
require "sinatra"
require "arionpay"

ARIONPAY = ArionPay::Client.new(
  api_key: ENV.fetch("ARIONPAY_API_KEY"),
  api_secret: ENV.fetch("ARIONPAY_API_SECRET"),
  webhook_secret: ENV.fetch("ARIONPAY_WEBHOOK_SECRET"),
  base_url: ENV.fetch("ARIONPAY_BASE_URL", ArionPay::DEFAULT_BASE_URL)
)

get "/checkout/:order_id" do
  invoice = ARIONPAY.create_invoice(
    amount: "49.90", currency: "USD", order_id: params[:order_id],
    success_url: "#{request.base_url}/thanks", cancel_url: "#{request.base_url}/cart",
    callback_url: "#{request.base_url}/arionpay/webhook",
    test: ENV["ARIONPAY_LIVE"] != "1"
  )
  redirect invoice["invoiceUrl"], 303
end

post "/arionpay/webhook" do
  request.body.rewind if request.body.respond_to?(:rewind) # Rack 3 bodies may not rewind
  raw = request.body.read
  begin
    event = ARIONPAY.verify_webhook(raw, request.env["HTTP_ARIONPAY_SIGNATURE"])
  rescue ArionPay::SignatureError
    halt 401
  end
  unless ArionPay.test_event?(event)
    invoice = event["data"]["invoice"]
    if event["type"] == "invoice.paid" && ArionPay.order_matches?(invoice, "49.90", "USD")
      warn "order #{invoice["orderId"]} paid (invoice #{invoice["id"]})" # deliver here, once per event["id"]
    end
  end
  status 200
end
