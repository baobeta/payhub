# typed: true
# frozen_string_literal: true

module Ops
  module Api
    class QueueController < BaseController
      requires_permission "ops.queue.read", only: :show

      def show = render(json: OpsQueue.call)
    end
  end
end
