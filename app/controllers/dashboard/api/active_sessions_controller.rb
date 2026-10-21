# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M7: the signed-in person's own sessions. Sign-in and sign-out stay in
    # SessionsController (the singular /session resource).
    class ActiveSessionsController < BaseController
      extend T::Sig
      include SessionListActions

      private

      sig { returns(ActiveSupport::Duration) }
      def idle_timeout = IDLE_TIMEOUT
    end
  end
end
