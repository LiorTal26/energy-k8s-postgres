[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "env.ps1")

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function Assert-LastExitCode {
    param([Parameter(Mandatory)][string]$Action)

    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

function Show-SmokeTestDiagnostics {
    & kubectl @KubectlArgs -n $Namespace describe job $JobName | Out-Host
    & kubectl @KubectlArgs -n $Namespace logs "job/$JobName" --all-containers=true | Out-Host
}

foreach ($Command in @("kubectl", "helm")) {
    Assert-Command $Command
}

& kubectl @KubectlArgs get namespace $Namespace | Out-Null
Assert-LastExitCode "Namespace lookup"

Write-Host "Checking the three-node Kind cluster..."
$NodesJson = & kubectl @KubectlArgs get nodes -o json | ConvertFrom-Json
Assert-LastExitCode "Reading node status"

$ValidNodes = @(
    $NodesJson.items | ForEach-Object {
        $ReadyCond = $_.status.conditions | Where-Object { $_.type -eq "Ready" }
        [PSCustomObject]@{
            Name  = $_.metadata.name
            Ready = ($ReadyCond.status -eq "True")
        }
    }
)

if ($ValidNodes.Count -ne 3 -or ($ValidNodes | Where-Object { -not $_.Ready })) {
    throw "Expected exactly three Ready Kind nodes. Current: $($ValidNodes.Count) nodes."
}

Write-Host "Checking pinned Helm releases..."
$ReleasesJson = & helm @HelmArgs list --namespace $Namespace -o json | ConvertFrom-Json
Assert-LastExitCode "Listing Helm releases"

$ExpectedReleases = @(
    @{ Name = $OperatorRelease; ExpectedChart = "pg-operator-$ChartVersion" },
    @{ Name = $DatabaseRelease; ExpectedChart = "pg-db-$ChartVersion" }
)

foreach ($Expected in $ExpectedReleases) {
    $Release = $ReleasesJson | Where-Object { $_.name -eq $Expected.Name }
    if (-not $Release) {
        throw "Helm release '$($Expected.Name)' is not installed."
    }

    if ($Release.status -ne "deployed" -or $Release.chart -ne $Expected.ExpectedChart) {
        throw "Helm release '$($Expected.Name)' is in status '$($Release.status)' with chart '$($Release.chart)' (expected deployed / $($Expected.ExpectedChart))."
    }
}

Write-Host "Checking the Operator rollout and Percona CRDs..."
foreach ($Crd in @(
    "perconapgclusters.pgv2.percona.com",
    "perconapgbackups.pgv2.percona.com",
    "perconapgrestores.pgv2.percona.com",
    "perconapgupgrades.pgv2.percona.com"
)) {
    & kubectl @KubectlArgs get crd $Crd | Out-Null
    Assert-LastExitCode "Checking CRD $Crd"
}

& kubectl @KubectlArgs -n $Namespace rollout status "deployment/$OperatorDeployment" --timeout "${TimeoutMinutes}m"
Assert-LastExitCode "Operator deployment rollout status"

Write-Host "Waiting for PerconaPGCluster '$DatabaseRelease' to report ready..."
$Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$ClusterReady = $false

while ((Get-Date) -lt $Deadline) {
    $State = & kubectl @KubectlArgs -n $Namespace get pg $DatabaseRelease -o jsonpath='{.status.state}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $State -eq "ready") {
        $ClusterReady = $true
        break
    }
    Start-Sleep -Seconds 5
}

if (-not $ClusterReady) {
    & kubectl @KubectlArgs -n $Namespace get pg,pods,pvc | Out-Host
    throw "PerconaPGCluster '$DatabaseRelease' did not reach state 'ready' within $TimeoutMinutes minutes."
}

Write-Host "Checking PostgreSQL, pgBouncer, pgBackRest, PVCs, and Pod placement..."
$PgPodsJson = & kubectl @KubectlArgs -n $Namespace get pods `
    -l "postgres-operator.crunchydata.com/cluster=$DatabaseRelease,postgres-operator.crunchydata.com/data=postgres" `
    -o json | ConvertFrom-Json
Assert-LastExitCode "PostgreSQL Pod lookup"

$PgPodRows = @(
    $PgPodsJson.items | ForEach-Object {
        [PSCustomObject]@{
            Name  = $_.metadata.name
            Node  = $_.spec.nodeName
            Phase = $_.status.phase
        }
    }
)

if ($PgPodRows.Count -ne 2) {
    throw "Expected two PostgreSQL Pods, found $($PgPodRows.Count)."
}

if ($PgPodRows[0].Node -eq $PgPodRows[1].Node) {
    throw "Anti-affinity check failed: both PostgreSQL Pods are scheduled on '$($PgPodRows[0].Node)'."
}

if ($PgPodRows | Where-Object { $_.Phase -ne "Running" }) {
    throw "Not all PostgreSQL Pods are Running."
}

$PgBouncerPods = & kubectl @KubectlArgs -n $Namespace get pods `
    -l "postgres-operator.crunchydata.com/cluster=$DatabaseRelease,postgres-operator.crunchydata.com/role=pgbouncer" `
    -o json | ConvertFrom-Json
Assert-LastExitCode "pgBouncer Pod lookup"

if (-not ($PgBouncerPods.items | Where-Object { $_.status.phase -eq "Running" })) {
    throw "pgBouncer Pod is not Running."
}

$RepoHostPods = & kubectl @KubectlArgs -n $Namespace get pods `
    -l "postgres-operator.crunchydata.com/cluster=$DatabaseRelease,postgres-operator.crunchydata.com/data=pgbackrest" `
    -o json | ConvertFrom-Json
Assert-LastExitCode "pgBackRest repo-host Pod lookup"

if (-not ($RepoHostPods.items | Where-Object { $_.status.phase -eq "Running" })) {
    throw "pgBackRest repository host Pod is not Running."
}

$Pvcs = & kubectl @KubectlArgs -n $Namespace get pvc `
    -l "postgres-operator.crunchydata.com/cluster=$DatabaseRelease" `
    -o json | ConvertFrom-Json
Assert-LastExitCode "PVC lookup"

$UnboundPvcs = @($Pvcs.items | Where-Object { $_.status.phase -ne "Bound" })
if ($UnboundPvcs.Count -gt 0) {
    throw "One or more PostgreSQL PVCs are not Bound."
}

Write-Host "Waiting for the Operator-generated application credential Secret..."
$SecretFound = $false
while ((Get-Date) -lt $Deadline) {
    & kubectl @KubectlArgs -n $Namespace get secret $CredentialSecret | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $SecretFound = $true
        break
    }
    Start-Sleep -Seconds 3
}

if (-not $SecretFound) {
    throw "Operator-generated Secret '$CredentialSecret' was not created."
}

Write-Host "Running the in-cluster SQL smoke test through pgBouncer..."
$SmokeTestManifest = Join-Path $RepositoryRoot "tests/smoke-test.yaml"

& kubectl @KubectlArgs -n $Namespace delete job $JobName --ignore-not-found | Out-Null
Assert-LastExitCode "Cleaning up previous smoke-test Job"

& kubectl @KubectlArgs apply -f $SmokeTestManifest | Out-Null
Assert-LastExitCode "Applying smoke-test Job manifest"

& kubectl @KubectlArgs -n $Namespace wait --for=condition=complete "job/$JobName" --timeout 10m | Out-Null
if ($LASTEXITCODE -ne 0) {
    Show-SmokeTestDiagnostics
    throw "Smoke-test Job did not complete successfully."
}

$SmokeTestLogs = & kubectl @KubectlArgs -n $Namespace logs "job/$JobName"
Assert-LastExitCode "Reading smoke-test Job logs"
$SmokeTestText = $SmokeTestLogs -join "`n"

Write-Host "`nSQL smoke-test output:" -ForegroundColor Cyan
Write-Host $SmokeTestText

if ($SmokeTestText -notmatch 'Percona PostgreSQL on Kubernetes is reachable') {
    Show-SmokeTestDiagnostics
    throw "Smoke-test logs did not contain the expected success text."
}

Write-Host "`nCluster summary:" -ForegroundColor Cyan
& kubectl @KubectlArgs -n $Namespace get pg,pods,pvc -o wide
