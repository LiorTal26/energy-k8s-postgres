[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "env.ps1")

if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
    throw "Required command 'kind' was not found."
}

if (-not $Force) {
    $Confirmation = Read-Host "This deletes the '$ClusterName' Kind cluster and all PostgreSQL data. Type DELETE to continue"
    if ($Confirmation -ne "DELETE") {
        Write-Host "Deletion cancelled."
        return
    }
}

& kind delete cluster --name $ClusterName
if (Test-Path -LiteralPath $Kubeconfig) {
    Remove-Item -LiteralPath $Kubeconfig -Force -ErrorAction SilentlyContinue
}
