# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Unknown /dashboard/api paths answer JSON 404, not the HTML shell the
    # catch-all shell route would otherwise serve.
    class FallbackController < BaseController
      skip_before_action :require_session!
      allow_unauthorized only: :show

      # Rendered directly: an unknown path is not a tenant-scoping miss, so it
      # must not count towards tenant_not_found.
      def show = render_api_error(ApiError.not_found("resource"))
    end
  end
end
