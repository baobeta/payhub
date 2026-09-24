# frozen_string_literal: true

# The one rule, proven live. Turns the Nordpay simulator hostile, drives the
# real HTTP API with concurrent duplicates and racing captures/refunds, then
# checks the books against the PSP's own records.
#
#   docker compose exec web bin/rails chaos:run          # 40 payments
#   docker compose exec web bin/rails "chaos:run[100]"
#
# Exits 1 if any invariant breaks. Restores the simulator's config afterwards.
namespace :chaos do
  desc "Run a chaos scenario against the Nordpay simulator and verify no double charge / over-refund"
  task :run, [:payments] => :environment do |_t, args|
    ok = ChaosRun.new(payments: (args[:payments] || 40).to_i).call
    exit(1) unless ok
  end
end

class ChaosRun
  HOSTILE = {
    "timeout_rate" => 0.15, "timeout_seconds" => 4, "flaky_500_rate" => 0.2, "duplicate_response_rate" => 0.2,
    "decline_rate" => 0.1, "webhook_duplicate_rate" => 0.3, "webhook_out_of_order_rate" => 0.3,
    "webhook_late_rate" => 0.1, "webhook_never_rate" => 0.1, "webhook_bad_signature_rate" => 0.1
  }.freeze
  COPIES = 3             # each Idempotency-Key is sent this many times, concurrently
  SETTLE_TIMEOUT = 300   # seconds; an unknown is first polled 2 min after it appears, by a once-a-minute sweeper
  UNSETTLED = %w[pending unknown requires_action].freeze

  def initialize(payments:)
    @count = payments
    @api = ENV.fetch("CHAOS_API_URL", "http://localhost:3000")
    @psp = Faraday.new(url: ENV.fetch("NORDPAY_URL", "http://localhost:4001"),
                       headers: { "Authorization" => "Bearer #{ENV.fetch('NORDPAY_API_KEY', 'np_test_key')}",
                                  "Content-Type" => "application/json" })
    @failures = []
  end

  def call
    @merchant, key = Merchant.create_with_api_key!(name: "Chaos #{Time.current.iso8601}", default_currency: "EUR")
    @http = Faraday.new(url: @api, headers: { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" }) do |f|
      f.options.timeout = 15
    end
    original = JSON.parse(@psp.put("/_sim/config", "{}").body)
    @preexisting = psp_charges.keys.to_set
    @psp.put("/_sim/config", HOSTILE.to_json)
    say "Nordpay is now hostile: #{HOSTILE.map { |k, v| "#{k.delete_suffix('_rate')}=#{v}" }.join(' ')}"

    create_payments
    wait_for("payments to leave pending/unknown") { payments.where(state: UNSETTLED).none? }
    race_captures
    wait_for("captures to land") { payments.where(state: "authorized").none? }
    race_refunds
    wait_for("refunds to settle") { Refund.where(payment: payments, state: "pending").none? }
    report
  ensure
    @psp.put("/_sim/config", original.to_json) if original
  end

  private

  def payments = @merchant.payments

  # Phase 1: every payment is requested COPIES times at once with the same key.
  def create_payments
    statuses = Hash.new(0)
    threads = Array.new(@count) do |i|
      idem = SecureRandom.uuid
      body = { amount_minor: 1_000 + (i * 37), currency: "EUR", payment_method_token: "tok_visa" }.to_json
      Array.new(COPIES) do
        Thread.new { @http.post("/v1/payments", body, "Idempotency-Key" => idem).status }
      end
    end.flatten
    threads.each { |t| statuses[t.value] += 1 }
    say "POST /v1/payments × #{threads.size} (#{@count} keys × #{COPIES}) → #{statuses.sort.map { |s, n| "#{n}×#{s}" }.join(', ')}"
  end

  # Phase 2: two full-amount captures race for each authorized payment.
  def race_captures
    targets = payments.where(state: "authorized").to_a
    fire(targets.flat_map { |p| Array.new(2) { ["/v1/payments/#{p.id}/capture", {}] } }, "capture (2 racing per payment)")
  end

  # Phase 3: three refunds of 60% race for each captured payment — at most one can fit.
  def race_refunds
    targets = payments.where(state: "captured").to_a
    fire(targets.flat_map { |p| Array.new(3) { ["/v1/payments/#{p.id}/refunds", { amount_minor: p.amount_minor * 6 / 10 }] } },
         "refund 60% (3 racing per payment)")
  end

  def fire(requests, label)
    statuses = Hash.new(0)
    requests.map { |path, body| Thread.new { @http.post(path, body.to_json, "Idempotency-Key" => SecureRandom.uuid).status } }
            .each { |t| statuses[t.value] += 1 }
    say "#{label}: #{requests.size} requests → #{statuses.sort.map { |s, n| "#{n}×#{s}" }.join(', ')}"
  end

  def wait_for(what)
    started = Time.current
    until yield
      if Time.current - started > SETTLE_TIMEOUT
        @failures << "timed out after #{SETTLE_TIMEOUT}s waiting for #{what}"
        return
      end
      sleep 2
    end
    say "…#{what}: #{(Time.current - started).round}s"
  end

  def report
    all = payments.includes(:refunds).to_a
    charges = psp_charges
    new_refs = charges.keys - @preexisting.to_a
    # Other merchants' stuck payments may be polled/charged meanwhile; those are
    # accounted for. An orphan is a charge that matches NO payment at all.
    orphans = new_refs - Payment.where(psp_reference: new_refs).pluck(:psp_reference)

    check("idempotency: #{@count} keys created exactly #{@count} payments", all.size == @count)
    # Every charge the PSP holds must belong to exactly one of our payments. A
    # retry that minted a fresh reference would show up here as an orphan.
    check("no orphan PSP charges — #{new_refs.size} new charges, #{orphans.size} unaccounted for",
          orphans.empty?)
    # Per payment: our books against the PSP's. Refunds are asked of the PSP
    # one by one, whatever state we think they are in.
    rows = all.map do |p|
      { id: p.id, captured: Ledger.captured_minor(p), refunded: Ledger.refunded_minor(p), reserved: Ledger.reserved_minor(p),
        psp_captured: charges.dig(p.psp_reference, "captured_minor").to_i,
        psp_refunded: p.refunds.sum { |r| psp_refund(r) } }
    end
    per_payment("money taken by the PSP == money captured in our ledger", rows) { |r| r[:captured] == r[:psp_captured] }
    per_payment("refunded ≤ captured", rows) { |r| r[:refunded] <= r[:captured] }
    per_payment("money refunded by the PSP == refunds in our ledger", rows) { |r| r[:refunded] == r[:psp_refunded] }
    per_payment("no refund reservation left once refunds settle", rows) { |r| r[:reserved].zero? }
    # What the PSP actually paid out: reconcile today's settlement report and
    # hold every line for these payments to the ledger (DECISIONS #18).
    SettlementReconciliationJob.perform_now(Time.current.utc.to_date.iso8601)
    lines = SettlementLine.where(psp_name: "nordpay", psp_reference: all.map(&:psp_reference))
    check("settlement report: #{lines.count} lines, #{lines.discrepancies.count} not matching the ledger", lines.discrepancies.none?)
    per_payment("every capture fully settled by the PSP", rows) { |r| Ledger.settled_minor(Payment.find(r[:id])) == r[:captured] }

    ours = LedgerEntry.where(payment: all).distinct.pluck(:transfer_id)
    check("every ledger transfer nets to zero (#{ours.size} transfers)", (Ledger.unbalanced_transfer_ids & ours).empty?)

    states = all.map(&:state).tally.sort.map { |s, n| "#{n} #{s}" }.join(", ")
    say "\nfinal states: #{states}"
    say "transitions through unknown: #{PaymentTransition.where(payment: all, to_state: 'unknown').count}"
    say(@failures.empty? ? "\n\e[32mThe one rule held.\e[0m" : "\n\e[31m#{@failures.size} violation(s).\e[0m")
    @failures.empty?
  end

  def psp_charges = JSON.parse(@psp.get("/_sim/charges").body).index_by { |c| c["reference"] }

  def psp_refund(refund)
    JSON.parse(@psp.get("/refunds/#{refund.psp_reference}").body).then { |r| r["status"] == "succeeded" ? r["amount_minor"] : 0 }
  end

  def per_payment(label, rows, &ok)
    bad = rows.reject(&ok)
    check("#{label} (#{rows.size - bad.size}/#{rows.size} payments)", bad.empty?)
    bad.each { |r| say "    #{r.inspect}" }
  end

  def check(label, passed)
    @failures << label unless passed
    say "#{passed ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m"} #{label}"
  end

  def say(msg) = puts(msg)
end
