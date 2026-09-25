# typed: false
# frozen_string_literal: true

# Runs a POST at most once per (merchant, key) and replays the stored answer
# (DECISIONS #3). Used by /v1 and by the UI's money-moving actions.
# typed: false: uses the controller API (request, response, render).
module IdempotentAction
  extend ActiveSupport::Concern

  class_methods do
    # Declare AFTER requires_permission: callbacks run in declaration order,
    # so a denied request never opens the guard's claim (design §3).
    def idempotent(only:)
      around_action :run_idempotently, only:
    end
  end

  private

  def idempotency_merchant = current_merchant
  def idempotency_key = request.headers["Idempotency-Key"].to_s

  # Runs the action at most once per (merchant, Idempotency-Key). The action
  # renders inside the guard so its status and body — including 4xx errors,
  # which are legitimate repeatable answers — are memoised. 5xx and raised
  # exceptions release the claim (see IdempotencyGuard#run).
  def run_idempotently(&action)
    if idempotency_key.empty?
      raise ApiError.invalid_request("Idempotency-Key header is required", param: "Idempotency-Key",
                                                                          code: "missing_idempotency_key")
    end

    guard = IdempotencyGuard.new(merchant: idempotency_merchant, key: idempotency_key,
                                 request_method: request.request_method, path: request.path, raw_body: request.raw_post)
    outcome = guard.call do
      begin
        action.call
      rescue ApiError => e
        render_api_error(e) # rescue_from runs outside around_action; store the error answer
      end
      [response.status, JSON.parse(response.body)]
    end
    return unless outcome.replayed

    response.set_header("Idempotent-Replayed", "true")
    render json: outcome.body, status: outcome.status
  end
end
