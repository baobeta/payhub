# Performance: listing payments at one million rows

`GET /v1/payments` uses keyset pagination on `(merchant_id, created_at DESC, id DESC)`. It uses no `OFFSET` and no `COUNT`, and fetches `LIMIT n+1` to learn `has_more`. To reproduce:

```bash
bin/rails "perf:seed[1000000]"   # one INSERT … SELECT generate_series; ~30s
bin/rails perf:explain           # EXPLAIN (ANALYZE, BUFFERS) of the page-2+ query
bin/rails perf:bench             # 20 runs, p50/p95
```

Result on a laptop (Postgres 16 in Docker), with the cursor in the middle of a 1M-row table:

```
Limit  (cost=0.42..5.35 rows=26 width=133) (actual time=0.061..0.333 rows=26 loops=1)
  Buffers: shared hit=12 read=23 written=19
  ->  Index Scan using idx_payments_cursor on payments  (cost=0.42..94653.31 rows=499316 width=133) (actual time=0.060..0.329 rows=26 loops=1)
        Index Cond: ((merchant_id = '…'::uuid) AND (ROW(created_at, id) < ROW('2026-08-08 08:30:39.41011', '01a0c84c-…'::uuid)))
Planning Time: 0.103 ms
Execution Time: 0.377 ms

p50=0.69ms  p95=1.21ms  max=2.17ms  (n=20, 1001008 rows)
```

The index goes straight to the page, touching 35 buffers out of 499,316 candidate rows. The list endpoint loads no transitions; `spec/requests/v1/payments_index_spec.rb` asserts exactly one `payments` query.
