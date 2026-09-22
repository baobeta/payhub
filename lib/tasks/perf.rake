# frozen_string_literal: true

# Performance proof for GET /v1/payments at scale.
#
#   bin/rails perf:seed[1000000]   # bulk-insert N payments for the demo merchant (idempotent-ish: adds N more)
#   bin/rails perf:explain         # EXPLAIN ANALYZE the exact cursor query; paste into README
#   bin/rails perf:bench           # time the endpoint's query 20× and report p50/p95
namespace :perf do
  desc "Bulk-insert N payments (default 1,000,000) spread over 90 days, via one INSERT ... SELECT generate_series"
  task :seed, [:count] => :environment do |_t, args|
    count = (args[:count] || 1_000_000).to_i
    merchant = Merchant.find_by!(name: "Demo Merchant")
    conn = ActiveRecord::Base.connection

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # One statement, no Ruby per row. Timestamps spread over 90 days so the
    # (created_at, id) keyset has realistic cardinality; states weighted like
    # production (most captured, some failed, a few stuck).
    conn.execute(<<~SQL)
      INSERT INTO payments (id, merchant_id, state, amount_minor, currency, captured_minor, merchant_currency, fx_rate,
                            psp_name, psp_reference, payment_method_token, capture_on_authorize, metadata,
                            lock_version, created_at, updated_at)
      SELECT uuid_generate_v7(),
             '#{merchant.id}'::uuid,
             (ARRAY['captured','captured','captured','captured','authorized','failed','refunded','part_refunded','pending','unknown'])[1 + (g % 10)],
             100 + (g::bigint * 7919) % 99900,
             (ARRAY['EUR','GBP','USD','VND','THB','IDR'])[1 + (g % 6)],
             0, 'EUR', 1,
             CASE WHEN g % 6 < 3 THEN 'nordpay' ELSE 'kiripay' END,
             'seed_' || g || '_' || substr(md5(random()::text), 1, 8),
             'tok_seed', false, '{}'::jsonb, 0,
             now() - (random() * interval '90 days'),
             now() - (random() * interval '90 days')
      FROM generate_series(1, #{count}) AS g
    SQL
    conn.execute("ANALYZE payments")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts "inserted #{count} payments in #{elapsed.round(1)}s; total now #{Payment.count}"
  end

  # The exact SQL Cursor.paginate emits for page 2+ of GET /v1/payments.
  def perf_cursor_sql(merchant, after)
    <<~SQL
      SELECT payments.* FROM payments
      WHERE payments.merchant_id = '#{merchant.id}'
        AND (payments.created_at, payments.id) < ('#{after.created_at.utc.iso8601(6)}', '#{after.id}')
      ORDER BY payments.created_at DESC, payments.id DESC
      LIMIT 26
    SQL
  end

  desc "EXPLAIN ANALYZE the cursor query against the current payments table"
  task explain: :environment do
    merchant = Merchant.find_by!(name: "Demo Merchant")
    # A cursor from the middle of the table: the worst case for OFFSET, the same case for keyset.
    after = merchant.payments.order(created_at: :desc, id: :desc).offset(Payment.count / 2).first
    puts "payments: #{Payment.count}  merchant's: #{merchant.payments.count}"
    puts
    puts perf_cursor_sql(merchant, after)
    puts
    ActiveRecord::Base.connection.execute("EXPLAIN (ANALYZE, BUFFERS) #{perf_cursor_sql(merchant, after)}")
                      .each { |row| puts row["QUERY PLAN"] }
  end

  desc "Time the cursor query 20 times; print p50 / p95"
  task bench: :environment do
    merchant = Merchant.find_by!(name: "Demo Merchant")
    after = merchant.payments.order(created_at: :desc, id: :desc).offset(Payment.count / 2).first
    sql = perf_cursor_sql(merchant, after)
    times = 20.times.map do
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveRecord::Base.connection.execute(sql)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    end.sort
    puts "p50=#{times[9].round(2)}ms  p95=#{times[18].round(2)}ms  max=#{times.last.round(2)}ms  (n=20, #{Payment.count} rows)"
  end
end
