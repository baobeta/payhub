# typed: strict
# frozen_string_literal: true

# Redacted from logs, exception reports and `inspect`. Matched as substrings,
# case-insensitively, against parameter names — so :number also covers
# card_number and :token covers payment_method_token.
#
# PCI note: this service never receives a PAN — the API takes a token only —
# but the filter is defence in depth for the day a client sends one anyway.
# spec/requests/v1/pan_never_logged_spec.rb proves a PAN-shaped string posted
# in any field does not reach the log.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # The spec's list:
  :card, :cvv, :number, :token, :authorization, :signature,
  # Opaque blobs from outside (merchant metadata, PSP webhook payloads). The
  # same list filters ActiveRecord's SQL bind logging, and a jsonb bind is
  # logged as one value — so a PAN inside metadata would leak at DEBUG level
  # unless the whole column is filtered. Found by pan_never_logged_spec.
  :metadata, :payload,
  # The memoised API response on idempotency_keys echoes merchant metadata back.
  :response_body
]
