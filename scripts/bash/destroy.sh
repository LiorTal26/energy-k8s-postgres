#!/usr/bin/env bash
set -Eeuo pipefail

readonly CLUSTER_NAME="energy-team"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly KUBECONFIG="${REPOSITORY_ROOT}/.tools/kubeconfig"

command -v kind >/dev/null 2>&1 || {
  echo "Required command 'kind' was not found." >&2
  exit 1
}

if [[ "${1:-}" != "--force" ]]; then
  read -r -p "This deletes the '${CLUSTER_NAME}' Kind cluster and all PostgreSQL data. Type DELETE to continue: " confirmation
  if [[ "${confirmation}" != "DELETE" ]]; then
    echo "Deletion cancelled."
    exit 0
  fi
fi

kind delete cluster --name "${CLUSTER_NAME}"
rm -f -- "${KUBECONFIG}"
