# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-14, M-15. Per mode: the test twin has its own endpoint and secret, so
    # test events can never reach the live endpoint.
    class WebhookEndpointsController < BaseController
      requires_permission "webhooks.read", only: :show
      requires_permission "webhooks.manage", only: %i[update reveal_secret roll_secret]

      def show = render(json: endpoint_json)

      def update
        url = params.require(:url).to_s
        problem = WebhookUrlGuard.problem(url)
        raise ApiError.validation("url" => [problem]) if problem

        current_merchant.update!(webhook_url: url)
        audit!("webhook.endpoint_updated", metadata: { "url" => url })
        render json: endpoint_json
      end

      def reveal_secret
        audit!("webhook.secret_revealed")
        render json: { "secret" => current_merchant.webhook_secret }
      end

      def roll_secret
        fresh = current_merchant.rotate_webhook_secret!
        audit!("webhook.secret_rolled")
        render json: endpoint_json.merge("secret" => fresh)
      end

      private

      def endpoint_json
        m = current_merchant
        expires = m.previous_webhook_secret_expires_at
        {
          "url" => m.webhook_url, "livemode" => m.livemode, "secret_last4" => m.webhook_secret.last(4),
          "previous_secret_expires_at" => expires&.future? ? expires.utc.iso8601 : nil
        }
      end
    end
  end
end
