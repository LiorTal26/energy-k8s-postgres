#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/bash/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

mkdir -p "${TOOLS_DIRECTORY}"

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

HELM_BIN="$(command -v helm || command -v helm.exe || echo helm)"

helm_for_cluster() {
  (
    cd "${REPOSITORY_ROOT}"
    if [[ "${HELM_BIN}" == *.exe* ]] || [[ -f /proc/version && $(cat /proc/version) =~ [Mm]icrosoft ]]; then
      "${HELM_BIN}" --kubeconfig ".tools/kubeconfig" --kube-context "${KUBE_CONTEXT}" "$@"
    else
      "${HELM_BIN}" --kubeconfig "${PROJECT_KUBECONFIG}" --kube-context "${KUBE_CONTEXT}" "$@"
    fi
  )
}

echo "Refreshing the official Percona Helm repository..."
"${HELM_BIN}" repo add percona https://percona.github.io/percona-helm-charts/ --force-update
"${HELM_BIN}" repo update percona

echo "Installing Percona Operator ${CHART_VERSION}..."
helm_for_cluster upgrade --install "${OPERATOR_RELEASE}" percona/pg-operator \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "helm/operator-values.yaml" \
  --reset-values \
  --wait \
  --timeout 10m

echo "Validating the Operator Deployment and CRD..."
kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  rollout status "deployment/${OPERATOR_DEPLOYMENT}" --timeout=10m
kubectl --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" \
  get crd perconapgclusters.pgv2.percona.com >/dev/null

echo "Installing PostgreSQL cluster..."
helm_for_cluster upgrade --install "${DATABASE_RELEASE}" percona/pg-db \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "helm/cluster-values.yaml" \
  --reset-values \
  --wait \
  --timeout 15m

echo "Bootstrap complete. Run scripts/bash/verify.sh to wait for readiness and execute SQL."
