# Chaos game day: run three experiments against the ledger and measure the impact from the client's
# side (the load generator's per-request log). Needs the cluster up and Chaos Mesh synced.
#
# Fault windows come from cluster events (pod Killing, Chaos Mesh Applied/Recovered), NOT from when
# an experiment was submitted: Chaos Mesh takes ~20-30 s to inject, which previously inflated MTTR.
# Writes docs/metrics/gameday-results.json for the postmortem and README.
param([int]$BaselineSeconds = 30, [string]$Only = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function ToEpoch([datetime]$d) { [DateTimeOffset]::new($d.ToUniversalTime()).ToUnixTimeSeconds() }

function Get-Requests([long]$from, [long]$to) {
    $since = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $from) + 10
    foreach ($l in (kubectl -n observability logs deploy/loadgen --since="${since}s" 2>$null)) {
        $p = $l -split ' '
        if ($p.Count -eq 3 -and $p[0] -match '^\d+$') {
            $ts = [long]$p[0]
            if ($ts -ge $from -and $ts -le $to) { [pscustomobject]@{ Ts = $ts; Code = $p[1]; Secs = [double]$p[2]; Ok = ($p[1] -match '^2') } }
        }
    }
}

function Get-EventTimes([string]$reason, [string]$objPrefix, [long]$notBefore) {
    $items = (kubectl -n payments get events -o json | ConvertFrom-Json).items
    $items | Where-Object { $_.reason -eq $reason -and $_.involvedObject.name -like "$objPrefix*" } |
        ForEach-Object { [DateTimeOffset]::Parse($_.lastTimestamp).ToUnixTimeSeconds() } |
        Where-Object { $_ -ge $notBefore }
}

function Wait-Healthy {
    for ($i = 0; $i -lt 60; $i++) {
        if ((kubectl -n payments get rollout ledger -o jsonpath='{.status.phase}') -eq "Healthy" -and
            [int](kubectl -n payments get rollout ledger -o jsonpath='{.status.availableReplicas}') -ge 3) { return }
        Start-Sleep 5
    }
    throw "ledger did not return to Healthy"
}

function Pct($vals, [double]$p) { if (-not $vals) { return $null }; $s = @($vals | Sort-Object); $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($p * $s.Count))] }

$experiments = @(
    @{ Name = "pod-kill-one";  File = "pod-kill-one.yaml"; Kind = "podchaos";     Obj = "kill-one-ledger-pod";  Window = 60;  Type = "kill" },
    @{ Name = "pod-kill-all";  File = "pod-kill-all.yaml"; Kind = "podchaos";     Obj = "kill-all-ledger-pods"; Window = 90;  Type = "kill" },
    @{ Name = "latency-400ms"; File = "latency.yaml";      Kind = "networkchaos"; Obj = "ledger-latency";       Window = 110; Type = "window" }
)

if ($Only) { $experiments = @($experiments | Where-Object { $_.Name -eq $Only }) }
function Utc([long]$e) { [DateTimeOffset]::FromUnixTimeSeconds($e).ToString("HH:mm:ss") }

$results = @()
foreach ($e in $experiments) {
    "`n=== $($e.Name) ==="
    Wait-Healthy
    "Baseline for ${BaselineSeconds}s ..."
    Start-Sleep $BaselineSeconds

    $submitted = ToEpoch (Get-Date)
    kubectl apply -f "$root\chaos\experiments\$($e.File)" | Out-Null
    "Chaos submitted; observing for $($e.Window)s ..."
    Start-Sleep $e.Window
    kubectl -n payments delete $e.Kind $e.Obj --ignore-not-found | Out-Null
    Wait-Healthy
    Start-Sleep 5

    if ($e.Type -eq "kill") {
        $kills = @(Get-EventTimes "Killing" "ledger-" $submitted)
        if (-not $kills) { throw "no pod Killing event found for $($e.Name)" }
        $faultStart = ($kills | Measure-Object -Minimum).Minimum
        $from = $faultStart - 5; $to = $faultStart + 40
    } else {
        $applied = @(Get-EventTimes "Applied" $e.Obj $submitted); $recovered = @(Get-EventTimes "Recovered" $e.Obj $submitted)
        if (-not $applied -or -not $recovered) { throw "no Applied/Recovered events for $($e.Name)" }
        $faultStart = ($applied | Measure-Object -Minimum).Minimum
        $from = $faultStart; $to = ($recovered | Measure-Object -Maximum).Maximum
    }

    $reqs = @(Get-Requests $from $to)
    $bad = @($reqs | Where-Object { -not $_.Ok })
    $okSecs = @($reqs | Where-Object Ok | ForEach-Object Secs)
    $outage = if ($bad.Count) { ($bad | Measure-Object Ts -Maximum).Maximum - ($bad | Measure-Object Ts -Minimum).Minimum + 1 } else { 0 }
    $span = [Math]::Max(1, $to - $from)
    $row = [ordered]@{
        experiment               = $e.Name
        submitted_utc            = Utc $submitted
        fault_start_utc          = Utc $faultStart
        window_utc               = "$(Utc $from) - $(Utc $to)"
        injection_lag_seconds    = $faultStart - $submitted
        fault_window_seconds     = $span
        requests                 = $reqs.Count
        request_rate_per_s       = [math]::Round($reqs.Count / $span, 1)
        failed                   = $bad.Count
        error_pct                = if ($reqs.Count) { [math]::Round(100 * $bad.Count / $reqs.Count, 2) } else { $null }
        share_over_250ms_pct     = if ($okSecs.Count) { [math]::Round(100 * @($okSecs | Where-Object { $_ -gt 0.25 }).Count / $okSecs.Count, 1) } else { $null }
        p50_ms                   = if ($okSecs) { [math]::Round(1000 * (Pct $okSecs 0.5)) } else { $null }
        p99_ms                   = if ($okSecs) { [math]::Round(1000 * (Pct $okSecs 0.99)) } else { $null }
        outage_seconds           = $outage
    }
    $results += [pscustomobject]$row
    [pscustomobject]$row | Format-List | Out-String | Write-Host
}

$out = "$root\docs\metrics\gameday-results.json"
@{ method = "fault windows from cluster events; client-side request log"; experiments = $results } | ConvertTo-Json -Depth 5 | Set-Content $out
"`nResults written to $out"
$results | Format-Table -AutoSize | Out-String -Width 220
