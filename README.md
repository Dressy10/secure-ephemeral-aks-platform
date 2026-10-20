# Internal developer platform on Azure, under a hard $50 budget

A small platform a team could use to ship a service safely. Security, reliability and cost are enforced by code.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Remote state, GitHub OIDC, Azure Policy, $50 budget, Infracost in PRs | scaffolded, not yet applied |
| 2 | Ephemeral compute, GitOps, PR preview environments | not started |
| 3 | Supply-chain signing, admission control, SLOs, canary | not started |
| 4 | Chaos game day, postmortem, demo | not started |

## Measured results (filled in as they are measured)

| Metric | Value |
|---|---|
| Long-lived secrets stored in Azure or GitHub | 0 Azure credentials (1 Infracost pricing key) |
| Cost per environment | TBD |
| Deploy time | TBD |
| MTTR in chaos test | TBD |

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
