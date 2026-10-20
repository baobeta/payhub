# typed: true
# frozen_string_literal: true

module Ops
  module Api
    # O-10: read-only circuit state. Operators never trip or close a circuit.
    class CircuitsController < BaseController
      extend T::Sig

      requires_permission "ops.circuits.read", only: :index

      sig { void }
      def index
        render json: { "data" => PspRouter::ADAPTERS.keys.map { PspCircuit.snapshot(_1) } }
      end
    end
  end
end
