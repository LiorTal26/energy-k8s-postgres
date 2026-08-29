#!/usr/bin/env bash
set -Eeuo pipefail

readonly KUBE_CONTEXT="kind-energy-team"
readonly NAMESPACE="postgres-operator"
readonly CLUSTER_NAME="energy-pg"
readonly OPERATOR_DEPLOYMENT="percona-operator-pg-operator"
readonly CREDENTIAL_SECRET="energy-pg-pguser-energyapp"
readonly JOB_NAME="postgres-smoke-test"
readonly TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-20}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly TOOLS_DIRECTORY="${REPOSITORY_ROOT}/.tools"
readonly PROJECT_KUBECONFIG="${KUBECONFIG:-${TOOLS_DIRECTORY}/kubeconfig}"

[[ "${TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]] &&
  (( TIMEOUT_MINUTES >= 1 && TIMEOUT_MINUTES <= 60 )) || {
  echo "TIMEOUT_MINUTES must be an integer from 1 through 60." >&2
  exit 1
}

readonly DEADLINE="$((SECONDS + TIMEOUT_MINUTES * 60))"

HELM_BIN="$(command -v helm || command -v helm.exe || echo helm)"
KUBECTL_BIN="$(command -v kubectl || command -v kubectl.exe || echo kubectl)"

[[ -f "${PROJECT_KUBECONFIG}" ]] || {
  echo "Kubeconfig '${PROJECT_KUBECONFIG}' was not found. Run scripts/bash/bootstrap.sh first." >&2
  exit 1
}

kube() {
  "${KUBECTL_BIN}" --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" "$@"
}

helm_for_cluster() {
  "${HELM_BIN}" --kubeconfig "${PROJECT_KUBECONFIG}" --kube-context "${KUBE_CONTEXT}" "$@"
}

show_smoke_test_diagnostics() {
  kube -n "${NAMESPACE}" describe job "${JOB_NAME}" || true
  kube -n "${NAMESPACE}" logs "job/${JOB_NAME}" --all-containers=true || true
}

for command_name in kubectl helm; do
  command -v "${command_name}" >/dev/null 2>&1 || command -v "${command_name}.exe" >/dev/null 2>&1 || {
    echo "Required command '${command_name}' was not found." >&2
    exit 1
  }
done

kube get namespace "${NAMESPACE}" >/dev/null

echo "Checking the three-node Kind cluster..."
node_names=( $(kube get nodes -o jsonpath='{.items[*].metadata.name}') )
node_ready_values=( $(kube get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{" "}{end}{end}') )

[[ "${#node_names[@]}" -eq 3 && "${#node_ready_values[@]}" -eq 3 ]] || {
  echo "Expected exactly three Kind nodes with Ready conditions." >&2
  exit 1
}
for ready_value in "${node_ready_values[@]}"; do
  [[ "${ready_value}" == "True" ]] || {
    echo "A Kind node is not Ready." >&2
    exit 1
  }
done

echo "Checking pinned Helm releases..."
for release_spec in "percona-operator:pg-operator-3.0.0" "energy-pg:pg-db-3.0.0"; do
  release="${release_spec%%:*}"
  expected_chart="${release_spec#*:}"
  row="$(helm_for_cluster --namespace "${NAMESPACE}" list --filter "^${release}$" --no-headers)"
  IFS=$'\t' read -r name namespace revision updated status chart app_version <<<"${row}"

  [[ "${name}" == "${release}" &&
     "${status}" == "deployed" &&
     "${chart}" == "${expected_chart}" ]] || {
    echo "Helm release '${release}' is missing or has an unexpected status or chart." >&2
    exit 1
  }
done

echo "Checking the Operator rollout and Percona CRDs..."
for crd in perconapgclusters.pgv2.percona.com perconapgbackups.pgv2.percona.com perconapgrestores.pgv2.percona.com perconapgupgrades.pgv2.percona.com; do
  kube get crd "${crd}" >/dev/null
done
kube -n "${NAMESPACE}" rollout status "deployment/${OPERATOR_DEPLOYMENT}" --timeout "${TIMEOUT_MINUTES}m"

echo "Waiting for PerconaPGCluster '${CLUSTER_NAME}' to report ready..."
while true; do
  state="$(kube -n "${NAMESPACE}" get pg "${CLUSTER_NAME}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  [[ "${state}" == "ready" ]] && break

  if (( SECONDS >= DEADLINE )); then
    kube -n "${NAMESPACE}" get pg,pods,pvc || true
    echo "PostgreSQL did not become ready within ${TIMEOUT_MINUTES} minutes." >&2
    exit 1
  fi

  sleep 5
done

echo "Checking PostgreSQL, pgBouncer, pgBackRest, PVCs, and Pod placement..."
pg_pod_lines="$(kube -n "${NAMESPACE}" get pods \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/data=postgres" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}')"

mapfile -t pg_pods <<<"${pg_pod_lines}"
[[ "${#pg_pods[@]}" -eq 2 ]] || {
  echo "Expected two PostgreSQL Pods, found ${#pg_pods[@]}." >&2
  exit 1
}

IFS=$'\t' read -r pg1_name pg1_node pg1_phase <<<"${pg_pods[0]}"
IFS=$'\t' read -r pg2_name pg2_node pg2_phase <<<"${pg_pods[1]}"

[[ "${pg1_node}" != "${pg2_node}" ]] || {
  echo "Anti-affinity check failed: both PostgreSQL Pods scheduled on '${pg1_node}'." >&2
  exit 1
}
[[ "${pg1_phase}" == "Running" && "${pg2_phase}" == "Running" ]] || {
  echo "Not all PostgreSQL Pods are Running." >&2
  exit 1
}

pgbouncer_phase="$(kube -n "${NAMESPACE}" get pods \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/role=pgbouncer" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
[[ "${pgbouncer_phase}" == "Running" ]] || {
  echo "pgBouncer Pod is not Running." >&2
  exit 1
}

repo_host_phase="$(kube -n "${NAMESPACE}" get pods \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/data=pgbackrest" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
[[ "${repo_host_phase}" == "Running" ]] || {
  echo "pgBackRest repository host Pod is not Running." >&2
  exit 1
}

unbound_pvcs="$(kube -n "${NAMESPACE}" get pvc \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME}" \
  -o jsonpath='{range .items[?(@.status.phase!="Bound")]}{.metadata.name}{" "}{end}')"
[[ -z "${unbound_pvcs// }" ]] || {
  echo "One or more PostgreSQL PVCs are not Bound: ${unbound_pvcs}" >&2
  exit 1
}

echo "Waiting for the Operator-generated application credential Secret..."
while true; do
  if kube -n "${NAMESPACE}" get secret "${CREDENTIAL_SECRET}" >/dev/null 2>&1; then
    break
  fi

  if (( SECONDS >= DEADLINE )); then
    echo "Operator-generated Secret '${CREDENTIAL_SECRET}' was not created." >&2
    exit 1
  fi

  sleep 3
done

echo "Running the in-cluster SQL smoke test through pgBouncer..."
kube -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null
kube apply -f "${REPOSITORY_ROOT}/tests/smoke-test.yaml" >/dev/null

if ! kube -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB_NAME}" --timeout=10m >/dev/null; then
  show_smoke_test_diagnostics
  echo "Smoke-test Job did not complete successfully." >&2
  exit 1
fi

smoke_test_logs="$(kube -n "${NAMESPACE}" logs "job/${JOB_NAME}")"
echo ""
echo "SQL smoke-test output:"
echo "${smoke_test_logs}"

if [[ "${smoke_test_logs}" != *"Percona PostgreSQL on Kubernetes is reachable"* ]]; then
  show_smoke_test_diagnostics
  echo "Smoke-test logs did not contain the expected success text." >&2
  exit 1
fi

echo ""
echo "Cluster summary:"
kube -n "${NAMESPACE}" get pg,pods,pvc -o wide
