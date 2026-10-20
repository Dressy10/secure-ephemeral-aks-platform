# Demo: admission control rejects images that are not signed by our build workflow.
# Requires the cluster up and Kyverno + policies synced, and ledger:unsigned-demo pushed
# (run the `demo-unsigned` workflow once: gh workflow run demo-unsigned).
$ErrorActionPreference = "Continue"

# Pod specs that satisfy PodSecurity "restricted", so rejection can only come from Kyverno.
function New-PodJson($name, $image) {
    @{
        apiVersion = "v1"; kind = "Pod"; metadata = @{ name = $name; namespace = "payments" }
        spec = @{
            restartPolicy = "Never"
            securityContext = @{ runAsNonRoot = $true; runAsUser = 65532; seccompProfile = @{ type = "RuntimeDefault" } }
            containers = @(@{
                name = "c"; image = $image
                securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @("ALL") } }
            })
        }
    } | ConvertTo-Json -Depth 8 -Compress
}

function Try-Deploy($title, $name, $image, $expect) {
    "`n--- $title"
    "    image: $image"
    $json = New-PodJson $name $image
    $out = $json | kubectl apply -f - 2>&1 | Out-String
    $out.Trim()
    if ($out -match "admission webhook .* denied" -and $out -match $expect) { "RESULT: BLOCKED by Kyverno, as expected." }
    elseif ($out -match "created") { Write-Warning "RESULT: the pod was ALLOWED. Check the policy."; kubectl -n payments delete pod $name --ignore-not-found | Out-Null }
    else { Write-Warning "RESULT: rejected, but not by the signing policy as expected." }
}

Try-Deploy "1. Foreign image (not from our registry)" "foreign-demo" "docker.io/library/nginx:1.27" "ledger|registry|dressy10"
Try-Deploy "2. Real image in OUR registry path, built but never signed" "unsigned-demo" "ghcr.io/dressy10/ledger:unsigned-demo" "no signatures|signature|verify"

"`n--- 3. The legitimately signed deployment is running:"
kubectl -n payments get pods -l app.kubernetes.io/name=ledger
