# Chaos game day: run three experiments against the ledger and measure the impact from the client's
# side (the load generator's per-request log). Needs the cluster up and Chaos Mesh synced.
# Writes docs/metrics/gameday-results.json for the postmortem and README.
param([int]$BaselineSeconds = 30)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Get-Requests([datetime]$from, [datetime]$to) {
    $since = [int][Math]::Ceiling(((Get-Date) - $from).TotalSeconds) + 5
    $lines = kubectl -n observability logs deploy/loadgen --since="${since}s" 2>$null
    $f = [DateTimeOffset]::new($from.ToUniversalTime()).ToUnixTimeSeconds()
    $t = [DateTimeOffset]::new($to.ToUniversalTime()).ToUnixTimeSeconds()
    foreach ($l in $lines) {
        $p = $l -split ' '
        if ($p.Count -eq 3 -and $p[0] -match '^\d+$') {
            $ts = [long]$p[0]
            if ($ts -ge $f -and $ts -le $t) { [pscustomobject]@{ Ts = $ts; Code = $p[1]; Secs = [double]$p[2]; Ok = ($p[1] -match '^2') } }
        }
    }
}

function Wait-Healthy {
    for ($i = 0; $i -lt 60; $i++) {
        if ((kubectl -n payments get rollout ledger -o jsonpath='{.status.phase}') -eq "Healthy" -and
            [int](kubectl -n payments get rollout ledger -o jsonpath='{.status.availableReplicas}') -ge 3) { return }
        Start-Sleep 5
    }
    throw "ledger did not return to Healthy"
}

function Pct($vals, [double]$p) { if (-not $vals) { return $null }; $s = $vals | Sort-Object; $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($p * $s.Count))] }

$experiments = @(
    @{ Name = "pod-kill-one";  File = "pod-kill-one.yaml"; Kind = "podchaos";     Obj = "kill-one-ledger-pod";  Window = 60 },
    @{ Name = "pod-kill-all";  File = "pod-kill-all.yaml"; Kind = "podchaos";     Obj = "kill-all-ledger-pods"; Window = 90 },
    @{ Name = "latency-400ms"; File = "latency.yaml";      Kind = "networkchaos"; Obj = "ledger-latency";       Window = 110 }
)

$results = @()
foreach ($e in $experiments) {
    "`n=== $($e.Name) ==="
    Wait-Healthy
    "Baseline for ${BaselineSeconds}s ..."
    Start-Sleep $BaselineSeconds

    $t1 = Get-Date
    kubectl apply -f "$root\chaos\experiments\$($e.File)" | Out-Null
    "Chaos applied at $($t1.ToString('HH:mm:ss')); observing for $($e.Window)s ..."
    Start-Sleep $e.Window
    kubectl -n payments delete $e.Kind $e.Obj --ignore-not-found | Out-Null
    Wait-Healthy
    Start-Sleep 5
    $t2 = Get-Date

    $reqs = @(Get-Requests $t1 $t2)
    $bad = @($reqs | Where-Object { -not $_.Ok })
    $okSecs = @($reqs | Where-Object Ok | ForEach-Object Secs)
    $f1 = [DateTimeOffset]::new($t1.ToUniversalTime()).ToUnixTimeSeconds()

    # MTTR: time from fault injection until the last failing request, i.e. when the client sees steady success again.
    $mttr = if ($bad.Count) { ($bad | Measure-Object Ts -Maximum).Maximum - $f1 + 1 } else { 0 }
    $firstFail = if ($bad.Count) { ($bad | Measure-Object Ts -Minimum).Minimum - $f1 } else { $null }
    $row = [ordered]@{
        experiment      = $e.Name
        requests        = $reqs.Count
        failed          = $bad.Count
        error_pct       = if ($reqs.Count) { [math]::Round(100 * $bad.Count / $reqs.Count, 2) } else { $null }
        slow_over_250ms_pct = if ($okSecs.Count) { [math]::Round(100 * @($okSecs | Where-Object { $_ -gt 0.25 }).Count / $okSecs.Count, 1) } else { $null }
        p50_ms          = if ($okSecs) { [math]::Round(1000 * (Pct $okSecs 0.5)) } else { $null }
        p99_ms          = if ($okSecs) { [math]::Round(1000 * (Pct $okSecs 0.99)) } else { $null }
        seconds_to_first_failure = $firstFail
        mttr_seconds    = $mttr
    }
    $results += [pscustomobject]$row
    [pscustomobject]$row | Format-List | Out-String | Write-Host
}

$out = "$root\docs\metrics\gameday-results.json"
$results | ConvertTo-Json | Set-Content $out
"`nResults written to $out"
$results | Format-Table -AutoSize | Out-String -Width 200
