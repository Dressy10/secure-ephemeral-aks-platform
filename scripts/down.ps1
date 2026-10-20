# Destroy the ephemeral cluster (and everything in rg-idp-platform).
. "$PSScriptRoot\_common.ps1"

Initialize-Tf "cluster" "cluster.tfstate"
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Tf "cluster" @("destroy", "-input=false", "-auto-approve")
$sw.Stop()

"{0:o} down {1:n0}s" -f (Get-Date), $sw.Elapsed.TotalSeconds | Add-Content "$Root\docs\metrics\cluster-timings.log"
"Cluster destroyed in {0:n0}s." -f $sw.Elapsed.TotalSeconds
