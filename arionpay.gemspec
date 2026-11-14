# frozen_string_literal: true

require_relative "lib/arionpay/version"

Gem::Specification.new do |spec|
  spec.name = "arionpay"
  spec.version = ArionPay::VERSION
  spec.authors = ["ArionPay"]
  spec.summary = "Official Ruby client for ArionPay crypto payments: invoices, signed webhooks, sandbox."
  spec.description = "Create crypto invoices (Bitcoin, USDT, Litecoin, Ethereum, TRON and more), send customers to the " \
                     "ArionPay payment page, and verify signed webhooks. Payments go straight to your own wallet. " \
                     "Standard library only; works with Rails, Sinatra, Hanami and any Rack app."
  spec.homepage = "https://arionpay.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = {
    "source_code_uri" => "https://github.com/ArionPay-Dev/arionpay-ruby",
    "changelog_uri" => "https://github.com/ArionPay-Dev/arionpay-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
