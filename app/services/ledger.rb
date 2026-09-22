# typed: strict
# frozen_string_literal: true

# The books. Every money movement is a transfer of two or more legs that sum
# to zero per currency, appended inside one transaction and never edited
# (DECISIONS #5). All balances and per-payment totals are SUMs over rows.
#
#   capture X:  debit psp_receivable X   / credit merchant_payable X
#   refund  Y:  debit merchant_payable Y / credit refunds_paid Y
module Ledger
  extend T::Sig

  class Unbalanced < StandardError; end

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

    sig { params(refund: Refund).returns(String) }
    def record_refund!(refund)
      payment = T.must(refund.payment)
      record!(
        merchant: T.must(payment.merchant), currency: refund.currency, payment: payment, refund: refund,
        legs: [
          Leg.new(account_kind: "merchant_payable", direction: "debit", amount_minor: refund.amount_minor),
          Leg.new(account_kind: "refunds_paid", direction: "credit", amount_minor: refund.amount_minor)
        ]
      )
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

    # GET /v1/balance: what we owe the merchant, per currency.
    sig { params(merchant: Merchant).returns(T::Hash[String, Integer]) }
    def balances(merchant)
      merchant.ledger_accounts.where(kind: "merchant_payable").to_h do |account|
        [account.currency, account.balance_minor]
      end
    end

    # Reconciliation: any transfer whose legs do not net to zero. Empty is healthy.
    sig { returns(T::Array[String]) }
    def unbalanced_transfer_ids
      LedgerEntry
        .group(:transfer_id, :currency)
        .having("SUM(CASE direction WHEN 'credit' THEN amount_minor ELSE -amount_minor END) <> 0")
        .pluck(:transfer_id)
    end

    private

    sig { params(payment: Payment, kind: String, direction: String).returns(Integer) }
    def sum_for(payment, kind:, direction:)
      LedgerEntry.joins(:account)
                 .where(payment: payment, direction: direction, ledger_accounts: { kind: kind })
                 .sum(:amount_minor).to_i
    end
  end
end
