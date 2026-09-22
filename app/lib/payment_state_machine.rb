# The single source of truth for which payment state changes are legal.
# Every transition — from the API, a worker, a webhook, the sweeper, or a
# console session — is checked against TRANSITIONS before it is written.
#
# The diagram this encodes is in README.md ("Domain model and schema").
module PaymentStateMachine
  STATES = %w[
    pending requires_action authorized unknown
    captured canceled failed part_refunded refunded
  ].freeze

  # States a payment can never leave.
  TERMINAL = %w[canceled failed refunded].freeze

  # States the sweeper must watch: the PSP outcome is not yet known.
  STUCK_CANDIDATES = %w[pending unknown].freeze

  class IllegalTransition < StandardError
    def initialize(from, to)
      super("illegal payment transition #{from} -> #{to}")
    end
  end

  # Exactly the edges drawn in the README diagram — no more, no less.
  # Each state is a claim about the PSP's view of the world, so an edge exists
  # only where we can honestly make the new claim (DECISIONS #11):
  #   - no unknown -> canceled: we can't release a hold we can't see;
  #     an operator giving up uses unknown -> failed with a reason.
  #   - no requires_action -> unknown: nothing is in flight to the PSP there,
  #     we're waiting on the customer; abandonment is failed, not ambiguity.
  TRANSITIONS = {
    pending:         %w[requires_action authorized unknown],
    requires_action: %w[authorized failed],
    unknown:         %w[authorized failed],
    authorized:      %w[captured canceled failed],
    captured:        %w[part_refunded refunded],
    part_refunded:   %w[refunded],
    canceled:        [],
    failed:          [],
    refunded:        []
  }.freeze

  module_function

  def legal?(from, to)
    TRANSITIONS.fetch(from.to_sym, []).include?(to.to_s)
  end

  def assert_legal!(from, to)
    raise IllegalTransition.new(from, to) unless legal?(from, to)
  end

  def terminal?(state) = TERMINAL.include?(state.to_s)
end
