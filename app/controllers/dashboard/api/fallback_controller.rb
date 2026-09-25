# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Unknown /dashboard/api paths answer JSON 404, not the HTML shell the
    # catch-all shell route would otherwise serve.
    class FallbackController < BaseController
      skip_before_action :require_session!
      allow_unauthorized only: :show

      def show = raise(ActiveRecord::RecordNotFound)
    end
  end
end
