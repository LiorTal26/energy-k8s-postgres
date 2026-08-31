# Central environment and configuration loader for PowerShell scripts and manual sessions.
# Loads configuration from the root config.env file and supports environment overrides.

if ($PSScriptRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
} else {
    $RepositoryRoot = (Get-Location).Path
}

$ConfigFile = Join-Path $RepositoryRoot "config.env"
if (Test-Path -LiteralPath $ConfigFile) {
    Get-Content -LiteralPath $ConfigFile | ForEach-Object {
        $Line = $_.Trim()
        if ($Line -and -not $Line.StartsWith("#") -and $Line.Contains("=")) {
            $Parts = $Line.Split("=", 2)
            $Key = $Parts[0].Trim()
            $Val = $Parts[1].Trim()
            if (-not [System.Environment]::GetEnvironmentVariable($Key)) {
                [System.Environment]::SetEnvironmentVariable($Key, $Val)
            }
        }
    }
}

# Resolved variables (environment override takes precedence over defaults)
$ClusterName        = if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "energy-team" }
$KubeContext        = if ($env:KUBE_CONTEXT) { $env:KUBE_CONTEXT } else { "kind-$ClusterName" }
$Namespace          = if ($env:NAMESPACE) { $env:NAMESPACE } else { "postgres-operator" }
$OperatorRelease    = if ($env:OPERATOR_RELEASE) { $env:OPERATOR_RELEASE } else { "percona-operator" }
$OperatorDeployment = if ($env:OPERATOR_DEPLOYMENT) { $env:OPERATOR_DEPLOYMENT } else { "percona-operator-pg-operator" }
$DatabaseRelease    = if ($env:DATABASE_RELEASE) { $env:DATABASE_RELEASE } else { "energy-pg" }
$ChartVersion       = if ($env:CHART_VERSION) { $env:CHART_VERSION } else { "3.0.0" }
$CredentialSecret   = if ($env:CREDENTIAL_SECRET) { $env:CREDENTIAL_SECRET } else { "$DatabaseRelease-pguser-energyapp" }
$DatabaseService    = if ($env:DATABASE_SERVICE) { $env:DATABASE_SERVICE } else { "$DatabaseRelease-pgbouncer" }
$JobName            = if ($env:JOB_NAME) { $env:JOB_NAME } else { "postgres-smoke-test" }
$AuthorizedJob      = if ($env:AUTHORIZED_JOB) { $env:AUTHORIZED_JOB } else { "np-authorized-probe" }
$UnauthorizedJob    = if ($env:UNAUTHORIZED_JOB) { $env:UNAUTHORIZED_JOB } else { "np-unauthorized-probe" }

$ToolsDirectory     = Join-Path $RepositoryRoot ".tools"
$Kubeconfig         = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $ToolsDirectory "kubeconfig" }

# Export environment variables for child processes (kubectl, helm, psql)
$env:KUBECONFIG       = $Kubeconfig
$env:HELM_CONFIG_HOME = Join-Path $ToolsDirectory "helm/config"
$env:HELM_CACHE_HOME  = Join-Path $ToolsDirectory "helm/cache"
$env:HELM_DATA_HOME   = Join-Path $ToolsDirectory "helm/data"

if (Test-Path -LiteralPath $Kubeconfig) {
    $KubectlArgs = @("--kubeconfig", $Kubeconfig, "--context", $KubeContext)
    $HelmArgs    = @("--kubeconfig", $Kubeconfig, "--kube-context", $KubeContext)
} else {
    $KubectlArgs = @("--context", $KubeContext)
    $HelmArgs    = @("--kube-context", $KubeContext)
}
