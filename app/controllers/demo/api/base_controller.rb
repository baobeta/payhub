# typed: true
# frozen_string_literal: true

module Demo
  module Api
    # Public by design: no login, test data only, one merchant. Every action
    # is public, so the declaration covers the whole controller.
    class BaseController < Web::BaseController
      wrap_parameters false
      allow_unauthorized

      rescue_from ActiveRecord::RecordNotFound do
        T.bind(self, Demo::Api::BaseController)
        render_api_error(ApiError.not_found("resource"))
      end

      rescue_from ActionController::ParameterMissing do |e|
        T.bind(self, Demo::Api::BaseController)
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end

      private

      def authorization_area = :merchant
      def merchant = @merchant ||= DemoMerchant.twin
    end
  end
end
