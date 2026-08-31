[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "env.ps1")
$NetworkPolicyManifest = Join-Path $RepositoryRoot "infrastructure/k8s/network-policy.yaml"
$ProbeManifest = Join-Path $RepositoryRoot "tests/network-policy-test.yaml"

if (-not (Test-Path -LiteralPath $Kubeconfig)) {
    throw "Kubeconfig '$Kubeconfig' was not found. Run scripts/powershell/bootstrap.ps1 first."
}

function Assert-LastExitCode {
    param([Parameter(Mandatory)][string]$Action)

    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

function Remove-ProbeJobs {
    & kubectl @KubectlArgs -n $Namespace delete job $AuthorizedJob $UnauthorizedJob --ignore-not-found --wait=true *> $null
}

function Show-ProbeDiagnostics {
    & kubectl @KubectlArgs -n $Namespace get jobs,pods -l "app.kubernetes.io/component=network-policy-probe" -o wide | Out-Host
    & kubectl @KubectlArgs -n $Namespace describe job $AuthorizedJob | Out-Host
    & kubectl @KubectlArgs -n $Namespace describe job $UnauthorizedJob | Out-Host
    & kubectl @KubectlArgs -n $Namespace logs "job/$AuthorizedJob" --all-containers=true | Out-Host
    & kubectl @KubectlArgs -n $Namespace logs "job/$UnauthorizedJob" --all-containers=true | Out-Host
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "Required command 'kubectl' was not found."
}

foreach ($Manifest in @($NetworkPolicyManifest, $ProbeManifest)) {
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "Required manifest '$Manifest' was not found."
    }
}

Write-Host "PostgreSQL NetworkPolicy enforcement test" -ForegroundColor Cyan
Write-Host "The test accepts only an expected psql connection timeout as proof of blocking."

try {
    Write-Host "`n[1/4] Checking the pgBouncer endpoint and generated Secret..." -ForegroundColor Yellow
    $EndpointAddress = & kubectl @KubectlArgs -n $Namespace get endpointslice `
        -l "kubernetes.io/service-name=$DatabaseService" `
        -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}'
    Assert-LastExitCode "pgBouncer EndpointSlice lookup"
    if ([string]::IsNullOrWhiteSpace($EndpointAddress)) {
        throw "Service '$DatabaseService' has no ready endpoint."
    }

    & kubectl @KubectlArgs -n $Namespace get secret $CredentialSecret | Out-Null
    Assert-LastExitCode "Credential Secret lookup"

    Write-Host "[2/4] Applying NetworkPolicies and isolated probe Jobs..." -ForegroundColor Yellow
    Remove-ProbeJobs
    & kubectl @KubectlArgs apply -f $NetworkPolicyManifest | Out-Null
    Assert-LastExitCode "NetworkPolicy apply"
    & kubectl @KubectlArgs apply -f $ProbeManifest | Out-Null
    Assert-LastExitCode "NetworkPolicy probe apply"

    Write-Host "[3/4] Verifying that the authorized client can query PostgreSQL..." -ForegroundColor Yellow
    & kubectl @KubectlArgs -n $Namespace wait --for=condition=complete "job/$AuthorizedJob" `
        --timeout "${TimeoutSeconds}s" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-ProbeDiagnostics
        throw "Authorized probe did not complete successfully."
    }

    $AuthorizedLogs = (& kubectl @KubectlArgs -n $Namespace logs "job/$AuthorizedJob" --all-containers=true) -join "`n"
    Assert-LastExitCode "Authorized probe log lookup"
    if ($AuthorizedLogs -notmatch 'AUTHORIZED_ACCESS_ALLOWED') {
        Show-ProbeDiagnostics
        throw "Authorized probe logs did not contain the expected SQL marker."
    }

    Write-Host "[4/4] Verifying that the unauthorized client is blocked for the expected reason..." -ForegroundColor Yellow
    & kubectl @KubectlArgs -n $Namespace wait --for=condition=failed "job/$UnauthorizedJob" `
        --timeout "${TimeoutSeconds}s" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-ProbeDiagnostics
        throw "Unauthorized probe did not reach the Job Failed condition."
    }

    $UnauthorizedPodJson = & kubectl @KubectlArgs -n $Namespace get pod `
        -l "job-name=$UnauthorizedJob" -o json | ConvertFrom-Json
    Assert-LastExitCode "Unauthorized probe Pod lookup"
    if (@($UnauthorizedPodJson.items).Count -ne 1) {
        throw "Expected exactly one unauthorized probe Pod."
    }

    $UnauthorizedPod = $UnauthorizedPodJson.items[0]
    $Terminated = $UnauthorizedPod.status.containerStatuses[0].state.terminated
    if ($UnauthorizedPod.status.phase -ne "Failed" -or $null -eq $Terminated) {
        Show-ProbeDiagnostics
        throw "Unauthorized probe did not run to a terminated Failed state."
    }
    if ($Terminated.exitCode -ne 2) {
        Show-ProbeDiagnostics
        throw "Unauthorized psql exited with code $($Terminated.exitCode); expected connection-failure code 2."
    }

    $UnauthorizedLogs = (& kubectl @KubectlArgs -n $Namespace logs $UnauthorizedPod.metadata.name --all-containers=true) -join "`n"
    Assert-LastExitCode "Unauthorized probe log lookup"
    $ExpectedTimeout = '(?is)connection to server.+port 5432 failed:\s*(connection timed out|timeout expired)'
    $UnrelatedFailure = '(?is)(could not translate host name|name or service not known|password authentication failed|database .+ does not exist|imagepull|secret .+ not found)'

    if ($UnauthorizedLogs -notmatch $ExpectedTimeout -or $UnauthorizedLogs -match $UnrelatedFailure) {
        Show-ProbeDiagnostics
        throw "Unauthorized probe failed, but not because NetworkPolicy caused the expected connection timeout."
    }

    Write-Host "`nNetworkPolicy enforcement verified:" -ForegroundColor Green
    Write-Host "  authorized SQL client: allowed"
    Write-Host "  unauthorized SQL client: blocked with the expected psql timeout"
}
finally {
    Remove-ProbeJobs
}
