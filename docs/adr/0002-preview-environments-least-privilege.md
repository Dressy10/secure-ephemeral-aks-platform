# ADR 0002: Preview environments share one namespace

Status: accepted

## Context
Each pull request should get a preview environment that is destroyed on merge. The obvious design is one namespace per PR. Creating a namespace needs cluster-wide rights, which would mean giving a PR-triggered CI identity cluster-admin. Any workflow code on a branch could then act as cluster-admin.

## Decision
- All previews live in one pre-created `previews` namespace (created by Flux, pod-security `restricted`).
- Each PR's resources are prefixed `pr-<N>-` and labelled `preview=pr-<N>`. Teardown deletes by label when the PR closes.
- The `gh-idp-preview` identity gets only:
  - AcrPush on the registry.
  - Cluster User Role, to fetch credentials.
  - RBAC Writer scoped to `.../namespaces/previews`.
  - Reader on the platform resource group.
- It has no subscription roles and no access to Terraform state. Fork PRs get no OIDC token, so they cannot deploy at all.
- These roles are granted in `infra/cluster`, so they disappear when the cluster is destroyed.

## Rejected
- A namespace per PR with cluster-admin for CI: too much power for an identity that PR authors can drive.
- Preview creation through Flux (a PR generator): the right long-term answer, but it needs extra controllers on a one-node cluster and is deferred.

## Consequences
- Previews share a node and a namespace, so isolation is by name and NetworkPolicy, not by namespace. Fine for a demo workload, not for multi-tenant production.
- Previews only exist while the cluster is up. The workflow skips cleanly when it is down.
