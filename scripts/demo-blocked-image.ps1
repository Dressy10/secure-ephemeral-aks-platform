# Demo: admission control rejects an unsigned/foreign image in the payments namespace.
# Requires the cluster to be up (scripts\up.ps1) and Kyverno + policies synced.
$ErrorActionPreference = "Continue"

"--- 1. Deploying an UNSIGNED image (docker.io/library/nginx:1.14, old and unverified) to payments ..."
kubectl -n payments run unsigned-demo --image=docker.io/library/nginx:1.14 --restart=Never 2>&1 | Tee-Object -Variable out
if ($out -match "denied|blocked|admission webhook") { "`nBLOCKED by admission control, as expected." } else { Write-Warning "Not blocked: check the policy." }

"`n--- 2. Same namespace, a lookalike under our registry path but never signed by our workflow ..."
kubectl -n payments run lookalike-demo --image=ghcr.io/dressy10/ledger:not-signed --restart=Never 2>&1 | Tee-Object -Variable out2
if ($out2 -match "denied|blocked|admission webhook|no signatures|verification") { "`nBLOCKED by signature verification, as expected." } else { Write-Warning "Not blocked: check the policy." }

"`n--- 3. The legitimately signed deployment is running:"
kubectl -n payments get pods
