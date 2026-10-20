# ADR 0003: GHCR plus keyless Cosign signing

Status: accepted

## Context
Images must be signed and verified at admission. ACR is destroyed with each cluster, so signed artifacts (signatures, SBOMs, attestations) would vanish with it.

## Decision
- Signed images live in GHCR, which is free and persistent. The workflow authenticates with its own `GITHUB_TOKEN`.
- Cosign signs keylessly. The signature is bound to this workflow's GitHub OIDC identity and logged in Sigstore's Rekor. There are no keys to store, rotate or leak.
- Kyverno verifies the signature against the exact workflow identity (`build.yml` on `main`), not merely "any signature".
- CI gates on Trivy (HIGH/CRITICAL with a fix available), then generates an SPDX SBOM with Syft and attests it, plus SLSA build provenance.
- Deployments reference an immutable digest that the pipeline writes into `gitops/`.

## Rejected
- Long-lived Cosign key pair in a secret: contradicts the zero-secrets goal.
- ACR for signed images: lifecycle is tied to the cluster.
- Kyverno enforcing the provenance attestation: GitHub stores provenance in a newer bundle format that Kyverno 1.13 does not read. Provenance is verified with `gh attestation verify` instead. Revisit when Kyverno supports it.
- Blocking vulnerable images at admission via a Trivy attestation: deferred. Today vulnerabilities are blocked at build time, and unsigned images are blocked at admission.

## Consequences
- The policy covers the `payments` namespace. Preview environments still use ACR images and are not signature-gated. This is a known gap.
- The GHCR package must be made public once, or the cluster needs a pull secret.
