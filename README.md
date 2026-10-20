# Internal developer platform on Azure, under a hard $50 budget

A small platform a team could use to ship a service safely. Security, reliability and cost are enforced by code.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Remote state, GitHub OIDC, Azure Policy, $50 budget, Infracost in PRs | done and applied |
| 2 | Ephemeral compute, GitOps, PR preview environments | done (verified end to end) |
| 3 | Supply-chain signing, admission control, SLOs, canary | done (verified on a live cluster) |
| 4 | Chaos game day, postmortem, demo | game day and postmortem done; demo video not recorded |

## Measured results

All figures come from real runs. Dollar figures are my own estimates from list prices, not billed amounts.

| Metric | Value |
|---|---|
| Long-lived secrets stored in Azure or GitHub | 0 Azure credentials. 1 Infracost pricing key (no cloud access). |
| Cluster create time, 1 node + Flux | 1,320 s (22 min) |
| Cluster create time, 2 nodes + Flux + Kyverno + Rollouts + Prometheus | 1,003 s (17 min) |
| Cluster destroy time | 1,068 s (18 min) |
| Cost while the cluster is up | about $0.15 per hour (2 x Standard_B2s, load balancer, ACR Basic) |
| Image signature enforcement | unsigned or foreign images rejected at admission (see `scripts/demo-blocked-image.ps1`) |
| Bad release: push to automatic rollback, end to end | 180 s (was 628 s before the Flux fix below); canary aborted about 55 s after it began progressing |
| Change propagation, git push to live cluster | 73 s (was 504 s: Flux health-checked the Argo Rollout, whose `observedGeneration` is a string, until a 10 min timeout) |
| Chaos: kill 1 of 3 pods | 0 or 1 failed request, outage 1 s or less (2 runs) |
| Chaos: kill all 3 pods, MTTR | about 3 s, self-healed, no human action (3 runs) |
| Chaos: +400 ms latency | every request slow (p50 about 810 ms), client throughput down about 63% |
| Vulnerabilities blocked at build | 25 HIGH or CRITICAL (Go stdlib) caught by the Trivy gate on the first real scan, fixed by upgrading the toolchain |

Measurement notes: the first game-day numbers were wrong and were corrected from raw logs; the full story, plus open action items, is in [the postmortem](docs/postmortems/2026-10-20-chaos-game-day.md). Results are from 2 to 3 runs on one small cluster, so they are indicative, not statistical.

## Layout

- `infra/bootstrap`: state storage and OIDC identities, applied once by hand
- `infra/landing-zone`: policies and budget
- `docs/adr`: architecture decision records

## Bootstrap

```powershell
az login
cd infra/bootstrap
terraform init
terraform apply -var subscription_id=<sub> -var github_repo=<owner>/<repo>
```

Then copy the outputs into GitHub repo variables: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_PLAN_CLIENT_ID`, `AZURE_APPLY_CLIENT_ID`, `TFSTATE_RG`, `TFSTATE_SA`, `BUDGET_CONTACTS`.

### OIDC subject

New GitHub repos use an immutable, ID-based OIDC subject (renaming or transferring the repo cannot hijack the identity). Fetch it with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` and pass it as `-var github_subject_prefix=<sub_claim_prefix>` when applying the bootstrap.
