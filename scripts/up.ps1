# Create the ephemeral cluster and record how long it took.
param([switch]$PlanOnly)
. "$PSScriptRoot\_common.ps1"

Initialize-Tf "cluster" "cluster.tfstate"
if ($PlanOnly) { Invoke-Tf "cluster" @("plan", "-input=false"); return }

$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Tf "cluster" @("apply", "-input=false", "-auto-approve")
$sw.Stop()

$acr = (terraform "-chdir=$Root\infra\cluster" output -raw acr_login_server).Split('.')[0]
# The registry is recreated with the cluster, so rebuild the dev image that Flux deploys.
az acr build -r $acr -t ledger:dev "$Root\app\ledger" --no-logs | Out-Null

$rg = terraform "-chdir=$Root\infra\cluster" output -raw resource_group
$name = terraform "-chdir=$Root\infra\cluster" output -raw cluster_name
az aks get-credentials -g $rg -n $name --overwrite-existing | Out-Null
kubelogin convert-kubeconfig -l azurecli 2>$null

"{0:o} up {1:n0}s" -f (Get-Date), $sw.Elapsed.TotalSeconds | Add-Content "$Root\docs\metrics\cluster-timings.log"
"Cluster up in {0:n0}s. Run scripts\down.ps1 when finished: it is billing until then." -f $sw.Elapsed.TotalSeconds
