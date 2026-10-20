# Demo: ship a deliberately bad release through GitOps and watch the canary auto-roll back.
# Requires the cluster up and `payments` healthy. Commits to main twice (bad, then restore).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$faults = "$root\gitops\apps\ledger\overlays\dev\faults.yaml"

function Set-FailRate([string]$rate) {
    (Get-Content $faults -Raw) -replace 'value: "[0-9.]+"', "value: `"$rate`"" | Set-Content $faults -NoNewline
}
function Phase { kubectl -n payments get rollout ledger -o jsonpath='{.status.phase}' 2>$null }

"--- Baseline: " + (Phase)
Set-FailRate "0.5"
git -C $root commit -qam "demo: ship 50% fault-injected release" ; git -C $root push -q origin main
$sw = [Diagnostics.Stopwatch]::StartNew()
"--- Pushed a bad release (FAIL_RATE=0.5). Waiting for Flux, the canary, and analysis ..."

$seenBad = $false
while ($sw.Elapsed.TotalMinutes -lt 12) {
    $p = Phase
    $msg = kubectl -n payments get rollout ledger -o jsonpath='{.status.message}' 2>$null
    "{0,5:n0}s  phase={1}  {2}" -f $sw.Elapsed.TotalSeconds, $p, $msg
    if ($p -eq "Degraded") { $seenBad = $true; break }
    Start-Sleep 15
}
if ($seenBad) { "`nCanary FAILED analysis and was rolled back automatically after {0:n0}s." -f $sw.Elapsed.TotalSeconds }
else { Write-Warning "Rollout did not degrade within 12 minutes. Inspect: kubectl -n payments describe rollout ledger" }

"`nPods serving traffic (stable ReplicaSet only):"
kubectl -n payments get pods -l app.kubernetes.io/name=ledger

"`n--- Restoring FAIL_RATE=0 in git ..."
Set-FailRate "0"
git -C $root commit -qam "demo: restore healthy config" ; git -C $root push -q origin main
"Done. Flux will roll the healthy config out through the same canary."
