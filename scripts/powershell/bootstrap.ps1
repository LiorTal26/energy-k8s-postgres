[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ClusterName = "energy-team"
$KubeContext = "kind-$ClusterName"
$Namespace = "postgres-operator"
$OperatorRelease = "percona-operator"
$DatabaseRelease = "energy-pg"
$ChartVersion = "3.0.0"
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ToolsDirectory = Join-Path $RepositoryRoot ".tools"
$Kubeconfig = Join-Path $ToolsDirectory "kubeconfig"

New-Item -ItemType Directory -Force -Path $ToolsDirectory | Out-Null
$env:HELM_CONFIG_HOME = Join-Path $ToolsDirectory "helm/config"
$env:HELM_CACHE_HOME = Join-Path $ToolsDirectory "helm/cache"
$env:HELM_DATA_HOME = Join-Path $ToolsDirectory "helm/data"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. See README.md prerequisites."
    }
}

function Assert-LastExitCode {
    param([Parameter(Mandatory)][string]$Action)

    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

foreach ($Command in @("docker", "kind", "kubectl", "helm")) {
    Assert-Command $Command
}

Write-Host "Checking the Docker engine..."
& docker info --format '{{.ServerVersion}}' | Out-Null
Assert-LastExitCode "Docker engine check"

$ExistingClusters = @(& kind get clusters)
Assert-LastExitCode "Listing Kind clusters"

if ($ExistingClusters -notcontains $ClusterName) {
    Write-Host "Creating Kind cluster '$ClusterName'..."
    & kind create cluster `
        --name $ClusterName `
        --config (Join-Path $RepositoryRoot "infrastructure/kind/cluster.yaml") `
        --kubeconfig $Kubeconfig `
        --wait 5m
    Assert-LastExitCode "Kind cluster creation"
}
else {
    Write-Host "Kind cluster '$ClusterName' already exists; reusing it."
    & kind export kubeconfig --name $ClusterName --kubeconfig $Kubeconfig
    Assert-LastExitCode "Refreshing the Kind kubeconfig"
}

Write-Host "Checking Kubernetes access..."
& kubectl --kubeconfig $Kubeconfig --context $KubeContext cluster-info | Out-Null
Assert-LastExitCode "Kubernetes access check"

& kubectl --kubeconfig $Kubeconfig --context $KubeContext get namespace $Namespace *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating namespace '$Namespace'..."
    & kubectl --kubeconfig $Kubeconfig --context $KubeContext create namespace $Namespace
    Assert-LastExitCode "Namespace creation"
}

Write-Host "Refreshing the official Percona Helm repository..."
& helm repo add percona https://percona.github.io/percona-helm-charts/ --force-update
Assert-LastExitCode "Adding the Percona Helm repository"
& helm repo update percona
Assert-LastExitCode "Updating the Percona Helm repository"

Write-Host "Installing Percona Operator $ChartVersion..."
& helm upgrade --install $OperatorRelease percona/pg-operator `
    --version $ChartVersion `
    --namespace $Namespace `
    --kube-context $KubeContext `
    --kubeconfig $Kubeconfig `
    --values (Join-Path $RepositoryRoot "helm/operator-values.yaml") `
    --reset-values `
    --wait `
    --timeout 10m
Assert-LastExitCode "Percona Operator installation"

Write-Host "Validating the Operator Deployment and CRD..."
& kubectl --kubeconfig $Kubeconfig --context $KubeContext -n $Namespace rollout status `
    deployment/percona-operator-pg-operator `
    --timeout 10m
Assert-LastExitCode "Percona Operator rollout"
& kubectl --kubeconfig $Kubeconfig --context $KubeContext get crd perconapgclusters.pgv2.percona.com | Out-Null
Assert-LastExitCode "PerconaPGCluster CRD check"

Write-Host "Installing PostgreSQL cluster $DatabaseRelease..."
& helm upgrade --install $DatabaseRelease percona/pg-db `
    --version $ChartVersion `
    --namespace $Namespace `
    --kube-context $KubeContext `
    --kubeconfig $Kubeconfig `
    --values (Join-Path $RepositoryRoot "helm/cluster-values.yaml") `
    --reset-values `
    --wait `
    --timeout 15m
Assert-LastExitCode "PostgreSQL cluster installation"

Write-Host "Bootstrap complete. Run scripts/powershell/verify.ps1 to wait for readiness and execute SQL."
