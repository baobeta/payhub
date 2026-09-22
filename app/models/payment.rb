# typed: true

class Payment < ApplicationRecord
  belongs_to :merchant
  has_many :transitions, -> { order(:sort_key, :created_at) },
           class_name: "PaymentTransition", dependent: :restrict_with_exception
  has_many :refunds, dependent: :restrict_with_exception
  has_many :ledger_entries, dependent: :restrict_with_exception

  PSPS = %w[nordpay kiripay].freeze

  validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: Currency::SUPPORTED }
  validates :merchant_currency, inclusion: { in: Currency::SUPPORTED }
  validates :state, inclusion: { in: PaymentStateMachine::STATES }
  validates :psp_name, inclusion: { in: PSPS }
  validates :psp_reference, :payment_method_token, presence: true
  validates :fx_rate, numericality: { greater_than: 0 }

  scope :stuck, ->(older_than:) {
    where(state: PaymentStateMachine::STUCK_CANDIDATES).where(updated_at: ..older_than)
  }

  # The psp_reference is OURS and exists before any network call, so a timed-out
  # charge can always be looked up (DECISIONS #2).
  def self.generate_psp_reference = "ph_#{SecureRandom.hex(12)}"

  # Every new payment starts life with a `pending` transition row so the
  # history is complete from the first moment.
  after_create :record_initial_transition

  # ── The only door to `state` ─────────────────────────────────────────────
  #
  # Applies `to_state` if (a) the edge is legal and (b) `sort_key` is not
  # older than the current most_recent transition. A stale event is still
  # recorded (most_recent: false) for the audit trail but does not move state.
  #
  # Returns the created PaymentTransition; check `#applied?` to know whether
  # state actually changed.
  #
  # Concurrency: the row is locked FOR UPDATE for the duration, and the
  # partial unique index on (payment_id) WHERE most_recent is the last line of
  # defence if two writers somehow both try to flip most_recent.
  def transition!(to_state, sort_key:, source:, metadata: {})
    to_state = to_state.to_s

    with_lock do
      current = transitions.find_by(most_recent: true)

      if current && sort_key < current.sort_key
        # Stale: the PSP told us something newer already. Record, don't apply.
        return transitions.create!(
          from_state: state, to_state: to_state, sort_key: sort_key, source: source,
          most_recent: false,
          metadata: metadata.merge("stale" => true, "superseded_by" => current.id)
        )
      end

      PaymentStateMachine.assert_legal!(state, to_state)

      current&.update_column(:most_recent, false)
      row = transitions.create!(
        from_state: state, to_state: to_state, sort_key: sort_key, source: source,
        most_recent: true, metadata: metadata
      )
      # write_attribute + save! so lock_version bumps and validations run
      write_attribute(:state, to_state)
      save!

      # Transactional outbox: the merchant-facing event is written in the SAME
      # transaction as the state change, so it exists iff the change committed.
      # Delivery happens later, by the sweeper.
      OutboundEvent.emit!(self, "payment.#{to_state}")
      row
    end
  end

  # Guard against `payment.update!(state: ...)` bypassing the history.
  def state=(value)
    raise ArgumentError, "use Payment#transition! — state is not assignable directly" unless new_record?

    super
  end

  def terminal? = PaymentStateMachine.terminal?(state)

  def display_amount = Currency.to_display(amount_minor, currency)

  private

  def record_initial_transition
    transitions.create!(
      from_state: nil, to_state: state, sort_key: created_at, source: "api", most_recent: true
    )
    OutboundEvent.emit!(self, "payment.created")
  end
end
