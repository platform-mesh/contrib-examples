#!/usr/bin/env bash
# hack/kind-down.sh — Delete the kind cluster (idempotent / ignore-not-found).
# Owner: k8s-expert
#
# Reads env vars exported by Taskfile.yml:
#   KIND_CLUSTER, KIND_KUBECONFIG, KCP_ADMIN_KUBECONFIG, KCP_CONTROLLER_KUBECONFIG
set -euo pipefail

: "${KIND_CLUSTER:?KIND_CLUSTER must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${KCP_CONTROLLER_KUBECONFIG:?KCP_CONTROLLER_KUBECONFIG must be set}"

echo "==> kind-down: cluster='${KIND_CLUSTER}'"

# Delete only if the cluster exists; treat absence as success (ignore-not-found).
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
  kind delete cluster --name "${KIND_CLUSTER}"
  echo "    cluster '${KIND_CLUSTER}' deleted"
else
  echo "    cluster '${KIND_CLUSTER}' not found — nothing to delete"
fi

# Remove stale kubeconfig files if they exist.
for kc in "${KIND_KUBECONFIG}" "${KCP_ADMIN_KUBECONFIG}" "${KCP_CONTROLLER_KUBECONFIG}"; do
  if [ -f "${kc}" ]; then
    rm -f "${kc}"
    echo "    removed ${kc}"
  fi
done

echo "==> kind-down: done"
