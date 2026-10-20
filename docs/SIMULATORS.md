# PSP simulators

| | Nordpay (`:4001`) | Kiripay (`:4002`) |
| --- | --- | --- |
| Currencies | EUR, GBP, USD | VND, THB, IDR (VND has no minor unit) |
| Model | Authorize, then capture; synchronous | Capture-only; redirect, then **webhook only** |
| Refunds | Partial | Full only |
| Idempotency | Honours `X-Request-Id` | None; PayHub dedupes by its own `merchant_reference` |
| Webhook signature | `X-Nordpay-Signature: <hmac-sha256 hex of body>` | `X-Kiripay-Signature: t=<unix>,v1=<hmac of "t.body">` |

Each simulator reads `failure_config.yml` and misbehaves at the configured rates:
- 30-second timeouts *after* recording the charge
- a `500` followed by a `200`
- the same charge twice in one response body
- a `200` with `status: declined`
- webhooks that are duplicated five times, reordered, hours late, badly signed or never sent

| Admin endpoint | Purpose |
| --- | --- |
| `X-Sim-Force: timeout,webhook_duplicate,…` | Request header that forces a behaviour for one request, keeping specs deterministic |
| `POST /_sim/reset` | Reset the simulator |
| `GET /_sim/charges` | List the charges it holds |
| `GET /_sim/webhooks` | List the webhooks it has sent |
| `PUT /_sim/config` | Change the failure rates |

Both simulators are standalone Sinatra apps under `simulators/`, each with its own `Gemfile` and specs (`cd simulators/nordpay && bundle exec rspec`).
