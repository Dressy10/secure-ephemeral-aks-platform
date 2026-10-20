# Runbook: ledger error-budget burn alert

Applies to `LedgerErrorBudgetFastBurn` (page) and `LedgerErrorBudgetSlowBurn` (ticket).

## 1. Is a rollout in flight?
```bash
kubectl -n payments get rollout ledger
kubectl -n payments describe rollout ledger | tail -30
```
- Phase `Paused` or `Progressing`: a canary is being analysed. Analysis aborts and rolls back by itself if the canary's success rate falls under 99%. Wait for it, then re-check the alert.
- Phase `Degraded` with `RolloutAborted`: the rollback already happened. Confirm the alert clears, then fix forward in git. Do not retry the same digest.

## 2. No rollout, errors still high
1. Check which pods return 5xx: `kubectl -n observability port-forward svc/prometheus-server 9090` and query `sum by (kubernetes_pod_name) (rate(ledger_http_requests_total{code="5xx"}[5m]))`.
2. Look at the audit log for rejected transfers and the reasons: `kubectl -n payments logs deploy/ledger | grep transfer_rejected`.
3. If it started with a deploy, revert the gitops commit (`git revert <sha>`). Flux rolls it back through the same canary.

## 3. After the incident
- Record the budget spent. If under 50% remains, apply the freeze in `docs/slo/ledger-slo.md`.
- Write a blameless postmortem for any page.
