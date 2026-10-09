# typed: true
# frozen_string_literal: true

module Ops
  module Api
    class MeController < BaseController
      allow_unauthorized only: :show # any signed-in operator may see who they are

      def show = render(json: OperatorMePresenter.call(current_user, current_session))
    end
  end
end
