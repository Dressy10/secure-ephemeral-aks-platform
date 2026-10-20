# Ledger SLOs and error budget

## Service level objectives (30-day window)
| SLI | Objective | Error budget |
|---|---|---|
| Availability: share of requests that do not return 5xx | 99.9% | 0.1% of requests (about 43 minutes of full outage per 30 days) |
| Latency: share of requests answered in under 250 ms | 99% | 1% of requests |

Both are measured from the service's own metrics (`ledger_http_requests_total`, `ledger_http_request_duration_seconds`).

## Burn-rate alerts
Alerts fire on how fast the budget is being spent, not on raw error counts. Each alert needs both a long and a short window, so it fires quickly but also clears quickly once the problem is fixed.

| Alert | Burn rate | Windows | Severity | Meaning |
|---|---|---|---|---|
| LedgerErrorBudgetFastBurn | over 14.4x | 1h and 5m | page | 2% of the monthly budget gone in an hour |
| LedgerErrorBudgetSlowBurn | over 6x | 6h and 30m | ticket | 5% of the monthly budget gone in six hours |
| LedgerLatencySLOBreach | over 1% slow | 5m, held 10m | ticket | more than 1% of requests above 250 ms |

Rules live in `gitops/infrastructure/prometheus.yaml`.

## Error budget policy
- Budget remaining above 50%: ship normally.
- Budget below 50%: only reliability work and fixes ship.
- Budget exhausted: freeze feature releases until the budget recovers.

## Known limitation
The demo Prometheus keeps 12 hours of data in memory and the cluster is deliberately short-lived. The 6h windows can only be evaluated while the cluster has been up that long, and the 30-day budget cannot be tracked across cluster rebuilds. In a real deployment this needs persistent storage (or a managed Prometheus) with at least 30 days of retention.
