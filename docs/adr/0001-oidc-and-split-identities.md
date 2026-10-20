# ADR 0001: GitHub OIDC with separate plan and apply identities

Status: accepted

## Context
CI needs to talk to Azure. The goal is zero long-lived secrets, and a pull request must not be able to change infrastructure.

## Decision
- GitHub Actions authenticates via workload identity federation. There are no client secrets and no storage keys. State storage has `shared_access_key_enabled = false`.
- Two app registrations:
  - `gh-idp-plan`: Reader plus state access. Trusted for `pull_request` and `main`.
  - `gh-idp-apply`: Contributor plus Resource Policy Contributor. Trusted only for the `production` GitHub environment, which requires manual approval.

## Rejected
- Service principal with a client secret: it is a long-lived secret that has to be rotated.
- One Contributor identity for everything: a malicious or buggy PR workflow could apply changes.
- Owner role for apply: Contributor plus Resource Policy Contributor is enough for policy assignments and does not allow RBAC changes.

## Consequences
- Role assignments for new identities are made in `infra/bootstrap`, which is applied by hand with an Owner-level human account.
- The Infracost API key is the one non-Azure secret in the repo. It is a free pricing-API key with no access to cloud resources.
