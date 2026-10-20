# typed: true
# frozen_string_literal: true

module Ops
  module Api
    class QueueController < BaseController
      extend T::Sig

      requires_permission "ops.queue.read", only: :show

      sig { void }
      def show = render(json: OpsQueue.call)
    end
  end
end
