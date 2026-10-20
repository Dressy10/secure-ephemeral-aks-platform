$ErrorActionPreference = "Stop"

$script:Root = Split-Path -Parent $PSScriptRoot
$script:SubscriptionId = (az account show --query id -o tsv)
$script:StateRg = "rg-idp-tfstate"
$script:StateSa = (az storage account list -g $StateRg --query "[0].name" -o tsv)

function Invoke-Tf {
    param([string]$Dir, [string[]]$TfArgs)
    $env:TF_VAR_subscription_id = $SubscriptionId
    terraform "-chdir=$Root\infra\$Dir" @TfArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs -join ' ') failed in $Dir" }
}

function Initialize-Tf {
    param([string]$Dir, [string]$Key)
    Invoke-Tf $Dir @("init", "-input=false", "-reconfigure",
        "-backend-config=resource_group_name=$StateRg",
        "-backend-config=storage_account_name=$StateSa",
        "-backend-config=container_name=tfstate",
        "-backend-config=key=$Key",
        "-backend-config=use_azuread_auth=true")
}
