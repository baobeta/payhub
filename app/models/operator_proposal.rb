# typed: true
# frozen_string_literal: true

# Maker-checker for manual money changes (DECISIONS #23). The database
# enforces the invariants (no self-approval, immutable payload); this model
# validates the payload's shape on the way in.
class OperatorProposal < ApplicationRecord
  KINDS = %w[payment_transition ledger_correction].freeze
  STATES = %w[pending withdrawn rejected applied failed].freeze
  REASON_CODES = %w[psp_confirmed_outcome psp_unreachable_timeout duplicate_booking ledger_error other].freeze
  # Operators move payments only out of `unknown` (DECISIONS #10). The other
  # stuck state, `pending`, is left to the worker and the sweeper.
  ALLOWED_TRANSITIONS = { "unknown" => %w[authorized failed] }.freeze

  belongs_to :payment
  belongs_to :proposed_by, class_name: "Operator"
  belongs_to :decided_by, class_name: "Operator", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :reason_code, inclusion: { in: REASON_CODES }
  validates :reason_text, :case_reference, :client_token, presence: true
  validate :payload_shape, on: :create

  scope :open, -> { where(state: "pending") }

  # TODO(user): Task 10.
  def approvable_by?(operator)
    raise NotImplementedError
  end

  def legs
    Array(payload["legs"]).map do |l|
      Ledger::Leg.new(account_kind: l.fetch("account_kind"), direction: l.fetch("direction"), amount_minor: Integer(l.fetch("amount_minor")))
    end
  end

  private

  def payload_shape
    kind == "ledger_correction" ? ledger_correction_shape : transition_shape
  end

  def transition_shape
    from = payment&.state
    to = payload["to_state"]
    return if ALLOWED_TRANSITIONS.fetch(from.to_s, []).include?(to)

    errors.add(:payload, "can move a #{from} payment only to #{ALLOWED_TRANSITIONS.fetch(from.to_s, []).join(' or ').presence || 'nothing'}")
  end

  def ledger_correction_shape
    unless Currency.supported?(payload["currency"].to_s)
      errors.add(:payload, "currency is not supported")
      return
    end
    parsed = legs
    net = parsed.sum { |l| l.direction == "credit" ? l.amount_minor : -l.amount_minor }
    errors.add(:payload, "legs must net to zero and number at least two") unless parsed.size >= 2 && net.zero?
    errors.add(:payload, "unknown account kind") unless parsed.all? { |l| LedgerAccount::KINDS.include?(l.account_kind) }
    errors.add(:payload, "amounts must be positive") unless parsed.all? { |l| l.amount_minor.positive? }
  rescue KeyError, ArgumentError, TypeError
    errors.add(:payload, "legs need account_kind, direction and a positive integer amount_minor")
  end
end
