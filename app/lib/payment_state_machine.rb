# typed: strict
# frozen_string_literal: true

# The single source of truth for which payment state changes are legal.
# Every transition — from the API, a worker, a webhook, the sweeper, or a
# console session — is checked against TRANSITIONS before it is written.
#
# The diagram this encodes is in README.md ("Domain model and schema").
module PaymentStateMachine
  extend T::Sig

  STATES = T.let(
    %w[pending requires_action authorized unknown captured canceled failed part_refunded refunded].freeze,
    T::Array[String]
  )

  # States a payment can never leave.
  TERMINAL = T.let(%w[canceled failed refunded].freeze, T::Array[String])

  # States the sweeper must watch: the PSP outcome is not yet known.
  STUCK_CANDIDATES = T.let(%w[pending unknown].freeze, T::Array[String])

  class IllegalTransition < StandardError
    extend T::Sig

    sig { params(from: T.any(String, Symbol), to: T.any(String, Symbol)).void }
    def initialize(from, to)
      super("illegal payment transition #{from} -> #{to}")
    end
  end

  # The edges drawn in the README diagram, plus two deliberate extras.
  # Each state is a claim about the PSP's view of the world, so an edge exists
  # only where we can honestly make the new claim (DECISIONS #10):
  #   + pending -> failed: a synchronous decline (Nordpay answers HTTP 200,
  #     status declined) is a definitive verdict straight from pending. The
  #     diagram omits it; routing through unknown or authorized would be a lie.
  #   + unknown -> requires_action: a capture-only PSP's create call timed out,
  #     the lookup found nothing, the re-send (same reference) produced a
  #     redirect. The honest state is "waiting on the customer". Found by the
  #     sweeper against real seed data, not by the diagram.
  #   - no unknown -> canceled: we can't release a hold we can't see;
  #     an operator giving up uses unknown -> failed with a reason.
  #   - no requires_action -> unknown: nothing is in flight to the PSP there,
  #     we're waiting on the customer; abandonment is failed, not ambiguity.
  TRANSITIONS = T.let(
    {
      pending: %w[requires_action authorized unknown failed],
      requires_action: %w[authorized failed],
      unknown: %w[authorized failed requires_action],
      authorized: %w[captured canceled failed],
      captured: %w[part_refunded refunded],
      part_refunded: %w[refunded],
      canceled: [],
      failed: [],
      refunded: []
    }.freeze,
    T::Hash[Symbol, T::Array[String]]
  )

  class << self
    extend T::Sig

    sig { params(from: T.any(String, Symbol), to: T.any(String, Symbol)).returns(T::Boolean) }
    def legal?(from, to)
      TRANSITIONS.fetch(from.to_sym, []).include?(to.to_s)
    end

    sig { params(from: T.any(String, Symbol), to: T.any(String, Symbol)).void }
    def assert_legal!(from, to)
      raise IllegalTransition.new(from, to) unless legal?(from, to)
    end

    sig { params(state: T.any(String, Symbol)).returns(T::Boolean) }
    def terminal?(state) = TERMINAL.include?(state.to_s)
  end
end
