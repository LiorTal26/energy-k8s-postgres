#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/bash/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

readonly PROMOTION_TIMEOUT_MINUTES="${PROMOTION_TIMEOUT_MINUTES:-5}"
readonly RECOVERY_TIMEOUT_MINUTES="${RECOVERY_TIMEOUT_MINUTES:-10}"
readonly CLUSTER_NAME="${DATABASE_RELEASE}"

for value in "${PROMOTION_TIMEOUT_MINUTES}" "${RECOVERY_TIMEOUT_MINUTES}"; do
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 20 )) || {
    echo "Failover timeouts must be integers from 1 through 20 minutes." >&2
    exit 1
  }
done

KUBECTL_BIN="$(command -v kubectl || command -v kubectl.exe || true)"
[[ -n "${KUBECTL_BIN}" ]] || {
  echo "Required command 'kubectl' was not found." >&2
  exit 1
}
[[ -f "${PROJECT_KUBECONFIG}" ]] || {
  echo "Kubeconfig '${PROJECT_KUBECONFIG}' was not found. Run scripts/bash/bootstrap.sh first." >&2
  exit 1
}

kube() {
  "${KUBECTL_BIN}" --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" "$@"
}

echo "PostgreSQL Pod failover and Operator self-healing"
echo "This test demonstrates Pod-level recovery on one Kind workstation; it is not production HA or a zero-downtime test."

echo ""
echo "[1/5] Identifying the current primary and replica..."
primary_pod="$(kube -n "${NAMESPACE}" get pods \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/role=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
replica_pod="$(kube -n "${NAMESPACE}" get pods \
  -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/role=replica" \
  -o jsonpath='{.items[0].metadata.name}')"

[[ -n "${primary_pod}" && -n "${replica_pod}" ]] || {
  echo "Could not identify exactly one current primary and one replica." >&2
  exit 1
}

replica_node="$(kube -n "${NAMESPACE}" get pod "${replica_pod}" -o jsonpath='{.spec.nodeName}')"
echo "  primary: ${primary_pod}"
echo "  replica: ${replica_pod} on ${replica_node}"

echo ""
echo "[2/5] Deleting the current primary Pod to simulate a Pod failure..."
promotion_started="${SECONDS}"
kube -n "${NAMESPACE}" delete pod "${primary_pod}" --now >/dev/null

echo "[3/5] Waiting for the former replica to be promoted..."
promotion_deadline="$((SECONDS + PROMOTION_TIMEOUT_MINUTES * 60))"
promoted=false
while (( SECONDS < promotion_deadline )); do
  current_role="$(kube -n "${NAMESPACE}" get pod "${replica_pod}" \
    -o jsonpath='{.metadata.labels.postgres-operator\.crunchydata\.com/role}' 2>/dev/null || true)"
  if [[ "${current_role}" == "primary" ]]; then
    promoted=true
    break
  fi
  sleep 2
done

[[ "${promoted}" == "true" ]] || {
  echo "The former replica was not promoted within ${PROMOTION_TIMEOUT_MINUTES} minutes." >&2
  exit 1
}
promotion_seconds="$((SECONDS - promotion_started))"
echo "  promotion completed in ${promotion_seconds} seconds"

echo "[4/5] Waiting for the Operator to restore two healthy PostgreSQL instances..."
recovery_started="${SECONDS}"
recovery_deadline="$((SECONDS + RECOVERY_TIMEOUT_MINUTES * 60))"
recovered=false

while (( SECONDS < recovery_deadline )); do
  state="$(kube -n "${NAMESPACE}" get pg "${CLUSTER_NAME}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  pod_rows="$(kube -n "${NAMESPACE}" get pods \
    -l "postgres-operator.crunchydata.com/cluster=${CLUSTER_NAME},postgres-operator.crunchydata.com/data=postgres" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null || true)"

  running_count="$(awk -F '\t' '$2 == "Running" {count++} END {print count+0}' <<<"${pod_rows}")"
  distinct_nodes="$(awk -F '\t' '$2 == "Running" {print $1}' <<<"${pod_rows}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
  unready_count="$(awk -F '\t' '$2 == "Running" && $3 ~ /false/ {count++} END {print count+0}' <<<"${pod_rows}")"
  ready_pod_count="$(awk -F '\t' '$2 == "Running" && $3 ~ /true/ && $3 !~ /false/ {count++} END {print count+0}' <<<"${pod_rows}")"

  if [[ "${state}" == "ready" && "${running_count}" == "2" && "${distinct_nodes}" == "2" && "${unready_count}" == "0" && "${ready_pod_count}" == "2" ]]; then
    recovered=true
    break
  fi
  sleep 3
done

if [[ "${recovered}" != "true" ]]; then
  kube -n "${NAMESPACE}" get pg,pods,pvc -o wide || true
  echo "The Operator did not restore two healthy instances within ${RECOVERY_TIMEOUT_MINUTES} minutes." >&2
  exit 1
fi
recovery_seconds="$((SECONDS - recovery_started))"
echo "  two-instance recovery completed in ${recovery_seconds} seconds after promotion"

echo "[5/5] Running the full verification and SQL write/read test through pgBouncer..."
KUBECONFIG="${PROJECT_KUBECONFIG}" TIMEOUT_MINUTES="${RECOVERY_TIMEOUT_MINUTES}" \
  bash "${SCRIPT_DIR}/verify.sh"

echo ""
echo "Pod failover and Operator self-healing verified."
echo "This result does not represent physical-host, storage-zone, or production availability testing."
