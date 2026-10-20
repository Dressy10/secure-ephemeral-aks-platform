# Runbook: verify an image's supply chain

Use when you need to prove where a running image came from, or when admission control rejects something.

## Verify the signature (Cosign, keyless)
```bash
cosign verify ghcr.io/dressy10/ledger@sha256:<digest> \
  --certificate-identity "https://github.com/Dressy10/secure-ephemeral-aks-platform/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Verify SLSA build provenance
```bash
gh attestation verify oci://ghcr.io/dressy10/ledger@sha256:<digest> --repo Dressy10/secure-ephemeral-aks-platform
```

## Inspect the SBOM
```bash
cosign verify-attestation --type spdxjson ghcr.io/dressy10/ledger@sha256:<digest> \
  --certificate-identity "https://github.com/Dressy10/secure-ephemeral-aks-platform/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com | jq -r '.payload' | base64 -d | jq '.predicate.packages[].name'
```

## A pod was rejected by admission
1. `kubectl -n payments describe replicaset <name>` shows the Kyverno message.
2. "no signatures found" means the image was not built by `build.yml` on `main`. Rebuild through the pipeline; never bypass the policy.
3. Emergency bypass is a PR that sets the policy to `Audit`. It needs review, and the follow-up to restore `Enforce` is mandatory.

## The package must be public
GHCR packages are private by default. After the first build, make `ledger` public (GitHub > Packages > ledger > Package settings), otherwise the cluster cannot pull it without a pull secret.
