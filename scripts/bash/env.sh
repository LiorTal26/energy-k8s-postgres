#!/usr/bin/env bash
# Central environment and configuration loader for Bash scripts and manual sessions.
# Loads configuration from the root config.env file and supports environment overrides.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${REPOSITORY_ROOT}/config.env"
if [[ -f "${CONFIG_FILE}" ]]; then
  # Load non-commented KEY=VALUE pairs without overriding existing environment variables
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    # Trim whitespace
    key="$(echo "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    value="$(echo "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    
    # Ignore empty lines and comments
    if [[ -n "${key}" && "${key}" != \#* ]]; then
      if [[ -z "${!key:-}" ]]; then
        export "${key}=${value}"
      fi
    fi
  done < "${CONFIG_FILE}"
fi

# Resolved variables
export CLUSTER_NAME="${CLUSTER_NAME:-energy-team}"
export KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
export NAMESPACE="${NAMESPACE:-postgres-operator}"
export OPERATOR_RELEASE="${OPERATOR_RELEASE:-percona-operator}"
export OPERATOR_DEPLOYMENT="${OPERATOR_DEPLOYMENT:-percona-operator-pg-operator}"
export DATABASE_RELEASE="${DATABASE_RELEASE:-energy-pg}"
export CLUSTER_NAME_PG="${DATABASE_RELEASE}"
export CHART_VERSION="${CHART_VERSION:-3.0.0}"
export CREDENTIAL_SECRET="${CREDENTIAL_SECRET:-${DATABASE_RELEASE}-pguser-energyapp}"
export DATABASE_SERVICE="${DATABASE_SERVICE:-${DATABASE_RELEASE}-pgbouncer}"
export JOB_NAME="${JOB_NAME:-postgres-smoke-test}"
export AUTHORIZED_JOB="${AUTHORIZED_JOB:-np-authorized-probe}"
export UNAUTHORIZED_JOB="${UNAUTHORIZED_JOB:-np-unauthorized-probe}"

export TOOLS_DIRECTORY="${REPOSITORY_ROOT}/.tools"
export PROJECT_KUBECONFIG="${KUBECONFIG:-${TOOLS_DIRECTORY}/kubeconfig}"
export KUBECONFIG="${PROJECT_KUBECONFIG}"

export HELM_CONFIG_HOME="${TOOLS_DIRECTORY}/helm/config"
export HELM_CACHE_HOME="${TOOLS_DIRECTORY}/helm/cache"
export HELM_DATA_HOME="${TOOLS_DIRECTORY}/helm/data"
