#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/bash/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

readonly TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"
readonly NETWORK_POLICY_MANIFEST="${REPOSITORY_ROOT}/infrastructure/k8s/network-policy.yaml"
readonly PROBE_MANIFEST="${REPOSITORY_ROOT}/tests/network-policy-test.yaml"

KUBECTL_BIN="$(command -v kubectl || command -v kubectl.exe || true)"
[[ -n "${KUBECTL_BIN}" ]] || {
  echo "Required command 'kubectl' was not found." >&2
  exit 1
}
[[ -f "${PROJECT_KUBECONFIG}" ]] || {
  echo "Kubeconfig '${PROJECT_KUBECONFIG}' was not found. Run scripts/bash/bootstrap.sh first." >&2
  exit 1
}
[[ -f "${NETWORK_POLICY_MANIFEST}" && -f "${PROBE_MANIFEST}" ]] || {
  echo "A required NetworkPolicy test manifest is missing." >&2
  exit 1
}
[[ "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] && (( TIMEOUT_SECONDS >= 30 && TIMEOUT_SECONDS <= 300 )) || {
  echo "TIMEOUT_SECONDS must be an integer from 30 through 300." >&2
  exit 1
}

kube() {
  "${KUBECTL_BIN}" --kubeconfig "${PROJECT_KUBECONFIG}" --context "${KUBE_CONTEXT}" "$@"
}

cleanup() {
  kube -n "${NAMESPACE}" delete job "${AUTHORIZED_JOB}" "${UNAUTHORIZED_JOB}" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

show_diagnostics() {
  kube -n "${NAMESPACE}" get jobs,pods \
    -l "app.kubernetes.io/component=network-policy-probe" -o wide || true
  kube -n "${NAMESPACE}" describe job "${AUTHORIZED_JOB}" || true
  kube -n "${NAMESPACE}" describe job "${UNAUTHORIZED_JOB}" || true
  kube -n "${NAMESPACE}" logs "job/${AUTHORIZED_JOB}" --all-containers=true || true
  kube -n "${NAMESPACE}" logs "job/${UNAUTHORIZED_JOB}" --all-containers=true || true
}

trap cleanup EXIT

echo "PostgreSQL NetworkPolicy enforcement test"
echo "The test accepts only an expected psql connection timeout as proof of blocking."

echo ""
echo "[1/4] Checking the pgBouncer endpoint and generated Secret..."
endpoint_address="$(kube -n "${NAMESPACE}" get endpointslice \
  -l "kubernetes.io/service-name=${DATABASE_SERVICE}" \
  -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}')"
[[ -n "${endpoint_address}" ]] || {
  echo "Service '${DATABASE_SERVICE}' has no ready endpoint." >&2
  exit 1
}
kube -n "${NAMESPACE}" get secret "${CREDENTIAL_SECRET}" >/dev/null

echo "[2/4] Applying NetworkPolicies and isolated probe Jobs..."
cleanup
kube apply -f "${NETWORK_POLICY_MANIFEST}" >/dev/null
kube apply -f "${PROBE_MANIFEST}" >/dev/null

echo "[3/4] Verifying that the authorized client can query PostgreSQL..."
if ! kube -n "${NAMESPACE}" wait --for=condition=complete "job/${AUTHORIZED_JOB}" \
  --timeout "${TIMEOUT_SECONDS}s" >/dev/null; then
  show_diagnostics
  echo "Authorized probe did not complete successfully." >&2
  exit 1
fi

authorized_logs="$(kube -n "${NAMESPACE}" logs "job/${AUTHORIZED_JOB}" --all-containers=true)"
if [[ "${authorized_logs}" != *"AUTHORIZED_ACCESS_ALLOWED"* ]]; then
  show_diagnostics
  echo "Authorized probe logs did not contain the expected SQL marker." >&2
  exit 1
fi

echo "[4/4] Verifying that the unauthorized client is blocked for the expected reason..."
if ! kube -n "${NAMESPACE}" wait --for=condition=failed "job/${UNAUTHORIZED_JOB}" \
  --timeout "${TIMEOUT_SECONDS}s" >/dev/null; then
  show_diagnostics
  echo "Unauthorized probe did not reach the Job Failed condition." >&2
  exit 1
fi

unauthorized_pod="$(kube -n "${NAMESPACE}" get pod -l "job-name=${UNAUTHORIZED_JOB}" \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${unauthorized_pod}" ]] || {
  show_diagnostics
  echo "Unauthorized probe Pod was not created." >&2
  exit 1
}

pod_phase="$(kube -n "${NAMESPACE}" get pod "${unauthorized_pod}" -o jsonpath='{.status.phase}')"
exit_code="$(kube -n "${NAMESPACE}" get pod "${unauthorized_pod}" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
terminated_reason="$(kube -n "${NAMESPACE}" get pod "${unauthorized_pod}" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}')"

if [[ "${pod_phase}" != "Failed" || "${terminated_reason}" != "Error" || "${exit_code}" != "2" ]]; then
  show_diagnostics
  echo "Unauthorized probe did not terminate as an executed psql connection failure." >&2
  exit 1
fi

unauthorized_logs="$(kube -n "${NAMESPACE}" logs "${unauthorized_pod}" --all-containers=true)"
if ! grep -Eqi 'connection to server.+port 5432 failed: (connection timed out|timeout expired)' <<<"${unauthorized_logs}"; then
  show_diagnostics
  echo "Unauthorized probe failed without the expected NetworkPolicy connection timeout." >&2
  exit 1
fi
if grep -Eqi 'could not translate host name|name or service not known|password authentication failed|database .+ does not exist|imagepull|secret .+ not found' <<<"${unauthorized_logs}"; then
  show_diagnostics
  echo "Unauthorized probe failed for an unrelated reason." >&2
  exit 1
fi

echo ""
echo "NetworkPolicy enforcement verified:"
echo "  authorized SQL client: allowed"
echo "  unauthorized SQL client: blocked with the expected psql timeout"
