# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class MeController < BaseController
      # Any signed-in user: no permission needed, but require_session! still runs.
      allow_unauthorized only: :show

      def show = render(json: MePresenter.call(current_user, current_session))
    end
  end
end
