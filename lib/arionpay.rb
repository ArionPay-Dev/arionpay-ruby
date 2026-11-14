# frozen_string_literal: true

# ArionPay: create crypto invoices, read them, and verify webhooks. Payments go straight to the merchant's own wallet.
# Use it on your server only: it holds your API secret.
require_relative "arionpay/version"
require_relative "arionpay/errors"
require_relative "arionpay/webhook"
require_relative "arionpay/client"
