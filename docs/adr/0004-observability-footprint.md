# ADR 0004: A minimal Prometheus, two small nodes

Status: accepted

## Context
The first node (`Standard_B2s`, 2 vCPU) already had about 77% of its CPU requested by Flux and system pods. Kyverno, Argo Rollouts, and a metrics stack would not fit. A full Prometheus, Grafana, and Loki stack is too heavy for the budget.

## Decision
- Run two `Standard_B2s` nodes (about +$0.05 per hour while the cluster is up, roughly $0.15 per hour in total). Cost stays bounded because the cluster is destroyed when idle.
- Run Prometheus only: no Alertmanager, Grafana, Loki, node-exporter or kube-state-metrics, no persistent volume, 12 hours of in-memory retention. It scrapes annotated pods, evaluates the SLO burn-rate rules, and feeds Argo Rollouts analysis.
- Logs stay on the pods (`kubectl logs`). The audit log is structured JSON on stdout.

## Rejected
- A bigger single node: doubles the price without adding schedulable CPU relative to a second small node.
- Azure Log Analytics or managed Prometheus: pay per ingested GB, harder to cap tightly, and metrics would live outside the cluster being destroyed. Worth revisiting for a persistent environment.
- Grafana and Loki: UI and log search are nice to have, but they do not change what the project demonstrates.

## Consequences
- Alerts are visible in Prometheus's alert view, not delivered anywhere. A real deployment adds Alertmanager (or a managed equivalent) and a pager.
- SLO history does not survive a cluster rebuild. See `docs/slo/ledger-slo.md`.
