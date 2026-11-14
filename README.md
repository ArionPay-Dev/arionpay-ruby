# ArionPay for Ruby

Official Ruby client for [ArionPay](https://arionpay.com). Create crypto invoices, send customers to the payment page, and check webhooks. The money goes straight to your own wallet: ArionPay never holds it.

- No dependencies (standard library only). Ruby 3.0 or newer.
- Works with Rails, Sinatra, Hanami, any Rack app or plain scripts.
- Safe retries: every invoice request carries an idempotency key, so a network error can never create two invoices.

```bash
gem install arionpay        # or in your Gemfile: gem "arionpay"
```

## Keys

In your ArionPay dashboard, open your store:

| Value | Where | Starts with |
| --- | --- | --- |
| API key | Store page, **API key** | `pk_` |
| API secret | Store page, **API secret** (asks for your authenticator code) | `sk_` |
| Webhook secret | **Webhooks** page, **signing secret** | `whsec_` |

Keep them on your server, for example in environment variables or Rails credentials.

## Take a payment

```ruby
require "arionpay"

ARIONPAY = ArionPay::Client.new(
  api_key: ENV.fetch("ARIONPAY_API_KEY"),
  api_secret: ENV.fetch("ARIONPAY_API_SECRET"),
  webhook_secret: ENV.fetch("ARIONPAY_WEBHOOK_SECRET")
)

invoice = ARIONPAY.create_invoice(
  amount: "49.90",
  currency: "USD",
  order_id: "1001",
  success_url: "https://shop.example.com/thanks/1001",
  cancel_url: "https://shop.example.com/cart",
  metadata: { "user_id" => 42 }
)
# send the customer to invoice["invoiceUrl"]
```

The customer coming back to `success_url` does **not** prove they paid. Deliver the order when the `invoice.paid` webhook arrives (or when `get_invoice` says `paid`).

Invoices are Hashes with string keys and the same field names as the webhook's `data.invoice` (`"id"`, `"status"`, `"orderId"`, `"amountFiat"`, `"currency"`, `"asset"`, `"paidCrypto"`, `"transactions"`, `"test"`, `"metadata"`, ...), so one method can handle a webhook and a read.

## Webhooks

Set your webhook address on the **Webhooks** page of the dashboard (a public `https://` address), or per invoice with `callback_url:`. Check the signature against the **raw** body, before you parse it.

### Rails

```ruby
# config/routes.rb:  post "/arionpay/webhook", to: "arionpay_webhooks#create"
class ArionpayWebhooksController < ActionController::API   # or ApplicationController with skip_forgery_protection
  def create
    event = ARIONPAY.verify_webhook(request.raw_post, request.headers["ArionPay-Signature"])
    handle_event(event) unless ArionPay.test_event?(event) # "Send test webhook": not a real order
    head :ok
  rescue ArionPay::SignatureError
    head :unauthorized
  end
end
```

### Sinatra

```ruby
post "/arionpay/webhook" do
  request.body.rewind if request.body.respond_to?(:rewind) # Rack 3 bodies may not rewind
  begin
    event = ARIONPAY.verify_webhook(request.body.read, request.env["HTTP_ARIONPAY_SIGNATURE"])
  rescue ArionPay::SignatureError
    halt 401
  end
  handle_event(event) unless ArionPay.test_event?(event)
  status 200
end
```

On Rack 3, `request.body.rewind` without the `respond_to?` check fails with `NoMethodError` on some servers (WEBrick, for one), and every webhook then gets a 500.

### Plain Rack

```ruby
raw = env["rack.input"].read
event = ARIONPAY.verify_webhook(raw, env["HTTP_ARIONPAY_SIGNATURE"])
```

No client at hand? `ArionPay.verify_webhook(raw, header, webhook_secret)` does the same.

### Handling an event

```ruby
def handle_event(event)
  return if WebhookEvent.exists?(event_id: event["id"]) # the same event can arrive more than once

  invoice = event["data"]["invoice"]
  order = Order.find_by(number: invoice["orderId"])
  if event["type"] == "invoice.paid" && order && !order.paid? &&
     ArionPay.order_matches?(invoice, order.total, order.currency) && invoice["test"] == order.test?
    order.mark_paid!(invoice) # deliver here
  end
  WebhookEvent.create!(event_id: event["id"])
end
```

`ArionPay.order_matches?(invoice, "49.90", "USD")` is true when the invoice price is that total, to the cent, in that currency.

| Event | Meaning | What to do |
| --- | --- | --- |
| `invoice.pending` | A payment was seen on the network and waits for confirmations. | Show "payment on its way". Do not deliver yet. |
| `invoice.partial` | Less than the full amount arrived. The invoice stays open for the rest. | Do not deliver. |
| `invoice.paid` | Fully paid and confirmed. Also sent when you accept a payment by hand in the dashboard. | Deliver the order. |
| `invoice.expired` | Time ran out without full payment. A late payment can still make it `paid`. | Keep the order unpaid. |
| `invoice.needs_review` | Something needs a person, for example more money arrived after the invoice was paid. | Tell a human. Do not change the order. |

ArionPay sends again when your server does not answer `2xx` (for about 3 days).

### Rules for a safe integration

1. Check the signature on the raw body. Never trust a webhook you could not verify.
2. Deliver only on `invoice.paid` (or when `get_invoice(id)["status"] == "paid"`).
3. Match the invoice to your order: your `order_id` or `metadata`, and the same amount and currency as the order's current total (`ArionPay.order_matches?`).
4. Ignore test events (`ArionPay.test_event?(event)`), and in your live shop ignore invoices with `"test" => true`.
5. Handle each `event["id"]` once, and answer `2xx` quickly (send emails from a background job).
6. Do not compare crypto amounts yourself. ArionPay decides when an invoice is paid, including payments inside your store's payment tolerance and payments you accept in Payment Radar.

## Test without real money

```ruby
invoice = ARIONPAY.create_invoice(amount: "10", order_id: "test-1", asset: "USDT_TRC20", test: true)
ARIONPAY.simulate_payment(invoice["id"], "exact") # your webhook gets invoice.paid, like a real payment
```

Scenarios: `exact`, `detected`, `confirm`, `underpaid_1pct`, `underpaid_5pct`, `overpaid`, `partial_half`, `late`.

`ARIONPAY.send_test_webhook("invoice.paid")` sends a signed sample event to your store's webhook address. It describes a made-up invoice (`inv_test_...`) and must never change an order.

Complete small shops: [`examples/config.ru`](examples/config.ru) (plain Rack) and [`examples/sinatra.rb`](examples/sinatra.rb).

## Reference

| Method | Returns |
| --- | --- |
| `create_invoice(amount:, currency: "USD", order_id: nil, ...)` | `{"id", "invoiceUrl", "status", "amountFiat", "currency", "asset", "address", "amountCrypto", "expiresAt", "orderId", "raw"}` |
| `get_invoice(invoice_id)` | The invoice, with the webhook field names (`"raw"` has every field ArionPay sent). |
| `simulate_payment(invoice_id, scenario = "exact")` | Sandbox only (test invoices). |
| `send_test_webhook(event_type = "invoice.paid")` | `{"delivered", "httpStatus", "eventId"}` |
| `currencies` | Coins you can pass as `asset:` / `allowed_assets:`. |
| `rates(currency = "USD")` | Current coin prices. |
| `verify_webhook(raw_body, signature_header)` | The event Hash, or raises `ArionPay::SignatureError`. Also a module method taking the secret as third argument. |

`create_invoice` keyword arguments: `amount:` (required), `currency:`, `order_id:`, `description:`, `customer_email:`, `success_url:`, `cancel_url:`, `callback_url:`, `asset:`, `allowed_assets:`, `expires_min:` (5 to 1440), `metadata:`, `idempotency_key:`, `test:`. `nil` values are not sent.

Errors from ArionPay are `ArionPay::APIError` with `status` (HTTP status, `0` when ArionPay could not be reached), `code` (for example `idempotency_key_reused`, `rate_limited`, `unknown_asset`) and `message`. Messages never contain your secret. Bad arguments raise `ArgumentError` before anything is sent.

`ArionPay::Client.new` options: `api_key:`, `api_secret:`, `webhook_secret:`, `base_url:` (default `https://merchant.arionpay.com`), `timeout:` (seconds, default 20), `max_attempts:` (default 3), `app_info:` (added to the User-Agent). A client is safe to share between threads (Puma, Sidekiq).

## Tests

```bash
rake test                   # unit tests; the live test is skipped
ARIONPAY_IT_BASE_URL=... ARIONPAY_IT_API_KEY=pk_... ARIONPAY_IT_API_SECRET=sk_... \
ARIONPAY_IT_WEBHOOK_SECRET=whsec_... ruby -Ilib -Itest test/test_integration.rb
```

## License

MIT
