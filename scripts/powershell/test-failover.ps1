[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$PromotionTimeoutMinutes = 5,

    [ValidateRange(1, 20)]
    [int]$RecoveryTimeoutMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "env.ps1")
$ClusterName = $DatabaseRelease

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "Required command 'kubectl' was not found."
}
if (-not (Test-Path -LiteralPath $Kubeconfig)) {
    throw "Kubeconfig '$Kubeconfig' was not found. Run scripts/powershell/bootstrap.ps1 first."
}

function Assert-LastExitCode {
    param([Parameter(Mandatory)][string]$Action)

    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

Write-Host "PostgreSQL Pod failover and Operator self-healing" -ForegroundColor Cyan
Write-Host "This test demonstrates Pod-level recovery on one Kind workstation; it is not production HA or a zero-downtime test."

Write-Host "`n[1/5] Identifying the current primary and replica..." -ForegroundColor Yellow
$PrimaryPod = & kubectl @KubectlArgs -n $Namespace get pods `
    -l "postgres-operator.crunchydata.com/cluster=$ClusterName,postgres-operator.crunchydata.com/role=primary" `
    -o jsonpath='{.items[0].metadata.name}'
Assert-LastExitCode "Primary Pod lookup"

$ReplicaPod = & kubectl @KubectlArgs -n $Namespace get pods `
    -l "postgres-operator.crunchydata.com/cluster=$ClusterName,postgres-operator.crunchydata.com/role=replica" `
    -o jsonpath='{.items[0].metadata.name}'
Assert-LastExitCode "Replica Pod lookup"

if ([string]::IsNullOrWhiteSpace($PrimaryPod) -or [string]::IsNullOrWhiteSpace($ReplicaPod)) {
    throw "Could not identify exactly one current primary and one replica."
}

$ReplicaNode = & kubectl @KubectlArgs -n $Namespace get pod $ReplicaPod -o jsonpath='{.spec.nodeName}'
Assert-LastExitCode "Replica node lookup"
Write-Host "  primary: $PrimaryPod"
Write-Host "  replica: $ReplicaPod on $ReplicaNode"

Write-Host "`n[2/5] Deleting the current primary Pod to simulate a Pod failure..." -ForegroundColor Yellow
$PromotionTimer = [Diagnostics.Stopwatch]::StartNew()
& kubectl @KubectlArgs -n $Namespace delete pod $PrimaryPod --now | Out-Null
Assert-LastExitCode "Primary Pod deletion"

Write-Host "[3/5] Waiting for the former replica to be promoted..." -ForegroundColor Yellow
$PromotionDeadline = (Get-Date).AddMinutes($PromotionTimeoutMinutes)
$Promoted = $false
while ((Get-Date) -lt $PromotionDeadline) {
    $CurrentRole = & kubectl @KubectlArgs -n $Namespace get pod $ReplicaPod `
        -o jsonpath='{.metadata.labels.postgres-operator\.crunchydata\.com/role}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $CurrentRole -eq "primary") {
        $Promoted = $true
        break
    }
    Start-Sleep -Seconds 2
}
$PromotionTimer.Stop()

if (-not $Promoted) {
    throw "The former replica was not promoted within $PromotionTimeoutMinutes minutes."
}
Write-Host ("  promotion completed in {0:N1} seconds" -f $PromotionTimer.Elapsed.TotalSeconds) -ForegroundColor Green

Write-Host "[4/5] Waiting for the Operator to restore two healthy PostgreSQL instances..." -ForegroundColor Yellow
$RecoveryTimer = [Diagnostics.Stopwatch]::StartNew()
$RecoveryDeadline = (Get-Date).AddMinutes($RecoveryTimeoutMinutes)
$Recovered = $false

while ((Get-Date) -lt $RecoveryDeadline) {
    $State = & kubectl @KubectlArgs -n $Namespace get pg $ClusterName -o jsonpath='{.status.state}' 2>$null
    $PodsJson = & kubectl @KubectlArgs -n $Namespace get pods `
        -l "postgres-operator.crunchydata.com/cluster=$ClusterName,postgres-operator.crunchydata.com/data=postgres" `
        -o json 2>$null | ConvertFrom-Json

    if ($LASTEXITCODE -eq 0 -and $null -ne $PodsJson) {
        $PostgresPods = @($PodsJson.items)
        $RunningPods = @($PostgresPods | Where-Object { $_.status.phase -eq "Running" })
        $DistinctNodes = @($RunningPods | ForEach-Object { $_.spec.nodeName } | Sort-Object -Unique)
        $ReadyPods = @(
            $RunningPods | Where-Object {
                $Statuses = @($_.status.containerStatuses)
                $Statuses.Count -gt 0 -and -not ($Statuses | Where-Object { -not $_.ready })
            }
        )

        if ($State -eq "ready" -and $RunningPods.Count -eq 2 -and $DistinctNodes.Count -eq 2 -and $ReadyPods.Count -eq 2) {
            $Recovered = $true
            break
        }
    }
    Start-Sleep -Seconds 3
}
$RecoveryTimer.Stop()

if (-not $Recovered) {
    & kubectl @KubectlArgs -n $Namespace get pg,pods,pvc -o wide | Out-Host
    throw "The Operator did not restore two healthy instances within $RecoveryTimeoutMinutes minutes."
}
Write-Host ("  two-instance recovery completed in {0:N1} seconds after promotion" -f $RecoveryTimer.Elapsed.TotalSeconds) -ForegroundColor Green

Write-Host "[5/5] Running the full verification and SQL write/read test through pgBouncer..." -ForegroundColor Yellow
& (Join-Path $PSScriptRoot "verify.ps1") -TimeoutMinutes $RecoveryTimeoutMinutes

Write-Host "`nPod failover and Operator self-healing verified." -ForegroundColor Green
Write-Host "This result does not represent physical-host, storage-zone, or production availability testing."
