# typed: true
# frozen_string_literal: true

# Per-request context, reset between requests by Rails. Jobs enqueued during
# a request capture request_id so their log line joins the request's.
class Current < ActiveSupport::CurrentAttributes
  attribute :request_id
end
