#!/usr/bin/env bash
set -Eeuo pipefail

readonly CLUSTER_NAME="energy-team"
readonly KUBE_CONTEXT="kind-${CLUSTER_NAME}"
readonly NAMESPACE="postgres-operator"
readonly CHART_VERSION="3.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly TOOLS_DIRECTORY="${REPOSITORY_ROOT}/.tools"
readonly PROJECT_KUBECONFIG="${KUBECONFIG:-${TOOLS_DIRECTORY}/kubeconfig}"

mkdir -p "${TOOLS_DIRECTORY}"
export HELM_CONFIG_HOME="${TOOLS_DIRECTORY}/helm/config"
export HELM_CACHE_HOME="${TOOLS_DIRECTORY}/helm/cache"
export HELM_DATA_HOME="${TOOLS_DIRECTORY}/helm/data"

for command_name in docker kind kubectl helm; do
  command -v "${command_name}" >/dev/null 2>&1 || command -v "${command_name}.exe" >/dev/null 2>&1 || {
    echo "Required command '${command_name}' was not found. See README.md prerequisites." >&2
    exit 1
  }
done

echo "Checking the Docker engine..."
docker info --format '{{.ServerVersion}}' >/dev/null

if ! kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
  echo "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${REPOSITORY_ROOT}/infrastructure/kind/cluster.yaml" \
    --kubeconfig "${PROJECT_KUBECONFIG}" \
    --wait 5m
else
  echo "Kind cluster '${CLUSTER_NAME}' already exists; reusing it."
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${PROJECT_KUBECONFIG}"
fi

kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" cluster-info >/dev/null

if ! kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" create namespace "${NAMESPACE}"
fi

echo "Refreshing the official Percona Helm repository..."
helm repo add percona https://percona.github.io/percona-helm-charts/ --force-update
helm repo update percona

echo "Installing Percona Operator ${CHART_VERSION}..."
helm upgrade --install percona-operator percona/pg-operator \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --kubeconfig "${PROJECT_KUBECONFIG}" \
  --values "${REPOSITORY_ROOT}/helm/operator-values.yaml" \
  --reset-values \
  --wait \
  --timeout 10m

echo "Validating the Operator Deployment and CRD..."
kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status deployment/percona-operator-pg-operator --timeout=10m
kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" \
  get crd perconapgclusters.pgv2.percona.com >/dev/null

echo "Installing PostgreSQL cluster..."
helm upgrade --install energy-pg percona/pg-db \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --kubeconfig "${PROJECT_KUBECONFIG}" \
  --values "${REPOSITORY_ROOT}/helm/cluster-values.yaml" \
  --reset-values \
  --wait \
  --timeout 15m

echo "Bootstrap complete. Run scripts/bash/verify.sh to wait for readiness and execute SQL."
