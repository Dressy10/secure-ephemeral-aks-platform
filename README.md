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
| PR checks (Terraform plan + Infracost cost comment) | verified on a real pull request: plan succeeded and the Infracost report was posted as a PR comment |
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

## How it works

```
Developer opens a PR
   |- Terraform plan + Infracost cost diff        (infra-pr.yml, OIDC login, no stored secrets)
   '- Preview environment deployed, torn down on close   (preview.yml)

PR merges to main
   '- build.yml: build -> Trivy gate (blocks HIGH/CRITICAL CVEs) -> push to GHCR
        -> Syft SBOM -> Cosign keyless signature -> SLSA provenance
        -> the new image digest is written into gitops/

Cluster (AKS, created on demand, destroyed when idle)
   |- Flux pulls gitops/ every 60 s
   |- Kyverno rejects any image not signed by this repo's build workflow
   |- Argo Rollouts runs a canary, checks Prometheus, and rolls back on its own
   '- Prometheus evaluates SLO burn-rate alerts
```

- **Identity:** GitHub Actions logs in to Azure through OIDC. There are separate `plan`, `apply` and `preview` identities, so a pull request can never change infrastructure, and the preview identity can only write to one namespace.
- **Guardrails:** Azure Policy (allowed regions and VM sizes, required tags, no public storage) and a $50 monthly budget that alerts at $25 and $40.
- **Ephemeral compute:** `scripts/up.ps1` builds the cluster and `scripts/down.ps1` destroys it, so it only costs money while someone is using it.
- **Proof, not claims:** the demos and the game day below exercise each control on a live cluster.

## How a team would use it

**Day to day, a product developer:**
1. Opens a PR and sees the plan, the cost impact and a running preview.
2. Merges. The pipeline scans, signs and deploys with no manual steps.
3. If a release is bad, the canary rolls it back automatically.
4. They never need `kubectl`, cloud credentials or a stored secret.

**To add a new service:** copy `app/ledger` and its folder under `gitops/apps/`, add the image to `build.yml`, extend the Kyverno policy in `gitops/policies/` to cover it, and add its SLOs and alert rules.

**The platform team** owns `infra/`, `gitops/policies/` and the workflows, and reviews changes to them.

## Limits

This is a demonstration of the pattern, not a drop-in platform for a company.
- **Not templated:** the registry path, workflow identity and registry name are tied to this repo and to the one `ledger` service. Another team would have to edit them.
- **Demo app:** the ledger keeps its state in memory.
- **Azure Policy is audit-only** (`policy_enforce = false`), so the guardrails report but do not block.
- **Cluster creation runs from scripts on a laptop,** not from CI.
- **Alerts are only visible inside Prometheus;** nothing pages anyone.
- **No SLO history across cluster rebuilds,** because the cluster and its metrics are destroyed.
- **Preview environments are not signature-gated** (they use ACR images, and the admission policy covers only the `payments` namespace).
- **Single region, single cluster.**
- **The demo video is not recorded yet.**
- **Dollar figures are my own estimates,** not billed amounts.

## Layout

- `infra/bootstrap`: state storage and OIDC identities, applied once by hand
- `infra/landing-zone`: Azure Policy guardrails and the budget
- `infra/cluster`: the disposable AKS cluster, ACR and Flux configuration
- `gitops/`: what Flux deploys (infrastructure, policies, apps)
- `app/ledger`: the sample payments-ledger service
- `chaos/`: Chaos Mesh experiments, applied only on demand
- `scripts/`: `up`, `down`, the game-day, rollback and blocked-image demos
- `.github/workflows/`: PR checks, preview environments, the signed build
- `docs/`: ADRs (`adr/`), runbooks (`runbooks/`), the SLO definition (`slo/`), the game-day postmortem (`postmortems/`) and raw measurements (`metrics/`)

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
