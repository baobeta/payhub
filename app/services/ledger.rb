# typed: strict
# frozen_string_literal: true

# The books. Every money movement is a transfer of two or more legs that sum
# to zero per currency, appended inside one transaction and never edited
# (DECISIONS #5). All balances and per-payment totals are SUMs over rows.
#
#   capture X:        debit psp_receivable X     / credit merchant_payable X
#   refund Y, two-phase (DECISIONS #16):
#     reserve (asked): debit merchant_payable Y   / credit refunds_reserved Y
#     post (PSP ok):   debit refunds_reserved Y   / credit refunds_paid Y
#     void (PSP no):   debit refunds_reserved Y   / credit merchant_payable Y
#
# A reservation is money no longer available to the merchant but not yet
# returned to the customer. It is a real balance, not a side calculation.
module Ledger
  extend T::Sig

  class Unbalanced < StandardError; end
  # Posting or voiding a refund whose reservation is missing: a bug upstream.
  class NoReservation < StandardError; end

  class Leg < T::Struct
    const :account_kind, String # LedgerAccount::KINDS
    const :direction, String    # debit | credit
    const :amount_minor, Integer
  end

  class << self
    extend T::Sig

    # Appends one balanced transfer. Raises Unbalanced BEFORE touching the
    # database if the legs do not net to zero, so a bug cannot leave a
    # half-written transfer behind.
    sig do
      params(merchant: Merchant, currency: String, legs: T::Array[Leg],
             payment: T.nilable(Payment), refund: T.nilable(Refund)).returns(String)
    end
    def record!(merchant:, currency:, legs:, payment: nil, refund: nil)
      net = legs.sum { |l| l.direction == "credit" ? l.amount_minor : -l.amount_minor }
      raise Unbalanced, "transfer nets to #{net} #{currency}, not 0" unless net.zero?
      raise Unbalanced, "a transfer needs at least two legs" if legs.size < 2

      transfer_id = SecureRandom.uuid
      LedgerEntry.transaction do
        legs.each do |leg|
          account = LedgerAccount.for(merchant, leg.account_kind, currency)
          LedgerEntry.create!(
            transfer_id: transfer_id, account: account, payment: payment, refund: refund,
            direction: leg.direction, amount_minor: leg.amount_minor, currency: currency
          )
        end
      end
      transfer_id
    end

    sig { params(payment: Payment, amount_minor: Integer).returns(String) }
    def record_capture!(payment, amount_minor)
      record!(
        merchant: T.must(payment.merchant), currency: payment.currency, payment: payment,
        legs: [
          Leg.new(account_kind: "psp_receivable", direction: "debit", amount_minor: amount_minor),
          Leg.new(account_kind: "merchant_payable", direction: "credit", amount_minor: amount_minor)
        ]
      )
    end

    # Phase 1, in the same transaction as the refund row: the money is spoken for.
    sig { params(refund: Refund).returns(String) }
    def reserve_refund!(refund)
      refund_transfer!(refund, from: "merchant_payable", to: "refunds_reserved")
    end

    # Phase 2a: the PSP returned the money to the customer.
    sig { params(refund: Refund).returns(String) }
    def post_refund!(refund)
      require_reservation!(refund)
      refund_transfer!(refund, from: "refunds_reserved", to: "refunds_paid")
    end

    # Phase 2b: the PSP refused; the reservation goes back to the merchant.
    sig { params(refund: Refund).returns(String) }
    def void_refund!(refund)
      require_reservation!(refund)
      refund_transfer!(refund, from: "refunds_reserved", to: "merchant_payable")
    end

    # ── Sums. Always from rows, never from a cached column. ─────────────────

    # Money actually taken from the customer for this payment.
    sig { params(payment: Payment).returns(Integer) }
    def captured_minor(payment)
      sum_for(payment, kind: "psp_receivable", direction: "debit")
    end

    # Money actually sent back for this payment (succeeded refunds only —
    # a refund's ledger legs are written on success).
    sig { params(payment: Payment).returns(Integer) }
    def refunded_minor(payment)
      sum_for(payment, kind: "refunds_paid", direction: "credit")
    end

    # Money spoken for by refunds still in flight at the PSP.
    sig { params(payment: Payment).returns(Integer) }
    def reserved_minor(payment)
      sum_for(payment, kind: "refunds_reserved", direction: "credit") -
        sum_for(payment, kind: "refunds_reserved", direction: "debit")
    end

    # GET /v1/balance "available": what we owe the merchant, per currency,
    # net of refunds already reserved.
    sig { params(merchant: Merchant).returns(T::Hash[String, Integer]) }
    def balances(merchant)
      balances_of(merchant, "merchant_payable")
    end

    # GET /v1/balance "pending": refunds reserved but not yet confirmed.
    sig { params(merchant: Merchant).returns(T::Hash[String, Integer]) }
    def reserved_balances(merchant)
      balances_of(merchant, "refunds_reserved")
    end

    # Reconciliation: any transfer whose legs do not net to zero. Empty is healthy.
    sig { returns(T::Array[String]) }
    def unbalanced_transfer_ids
      LedgerEntry
        .group(:transfer_id, :currency)
        .having("SUM(CASE direction WHEN 'credit' THEN amount_minor ELSE -amount_minor END) <> 0")
        .pluck(:transfer_id)
    end

    # Reconciliation: refunds whose reservation disagrees with their state —
    # a pending refund must hold exactly its amount, a settled one nothing.
    sig { returns(T::Array[String]) }
    def reservation_drift_refund_ids
      held = LedgerEntry.joins(:account).where(ledger_accounts: { kind: "refunds_reserved" })
                        .group(:refund_id)
                        .sum(Arel.sql("CASE direction WHEN 'credit' THEN amount_minor ELSE -amount_minor END"))
      Refund.where(id: held.keys).or(Refund.where(state: "pending")).pluck(:id, :state, :amount_minor)
            .reject { |id, state, amount| held.fetch(id, 0).to_i == (state == "pending" ? amount : 0) }
            .map(&:first)
    end

    private

    sig { params(refund: Refund, from: String, to: String).returns(String) }
    def refund_transfer!(refund, from:, to:)
      payment = T.must(refund.payment)
      record!(
        merchant: T.must(payment.merchant), currency: refund.currency, payment: payment, refund: refund,
        legs: [
          Leg.new(account_kind: from, direction: "debit", amount_minor: refund.amount_minor),
          Leg.new(account_kind: to, direction: "credit", amount_minor: refund.amount_minor)
        ]
      )
    end

    sig { params(refund: Refund).void }
    def require_reservation!(refund)
      held = LedgerEntry.joins(:account)
                        .where(refund: refund, direction: "credit", ledger_accounts: { kind: "refunds_reserved" }).exists?
      raise NoReservation, "refund #{refund.id} has no reservation to settle" unless held
    end

    sig { params(merchant: Merchant, kind: String).returns(T::Hash[String, Integer]) }
    def balances_of(merchant, kind)
      merchant.ledger_accounts.where(kind: kind).to_h { |account| [account.currency, account.balance_minor] }
    end

    sig { params(payment: Payment, kind: String, direction: String).returns(Integer) }
    def sum_for(payment, kind:, direction:)
      LedgerEntry.joins(:account)
                 .where(payment: payment, direction: direction, ledger_accounts: { kind: kind })
                 .sum(:amount_minor).to_i
    end
  end
end
