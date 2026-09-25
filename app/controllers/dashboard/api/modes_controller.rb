# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-18: switches which data space this session reads, live or the test twin.
    class ModesController < BaseController
      allow_unauthorized only: :update # every role may look at test data

      def update
        livemode = ActiveModel::Type::Boolean.new.cast(params.require(:livemode))
        current_session.update!(livemode:)
        render json: MePresenter.call(current_user, current_session)
      end
    end
  end
end
