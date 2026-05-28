#!/usr/bin/env bash
# hack/kind-down.sh — Delete the kind cluster (idempotent / ignore-not-found).
# Owner: k8s-expert
#
# Reads env vars exported by Taskfile.yml:
#   KIND_CLUSTER, KIND_KUBECONFIG
set -euo pipefail

: "${KIND_CLUSTER:?KIND_CLUSTER must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"

echo "==> kind-down: cluster='${KIND_CLUSTER}'"

# Delete only if the cluster exists; treat absence as success (ignore-not-found).
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
  kind delete cluster --name "${KIND_CLUSTER}"
  echo "    cluster '${KIND_CLUSTER}' deleted"
else
  echo "    cluster '${KIND_CLUSTER}' not found — nothing to delete"
fi

# Remove the stale kubeconfig file if it exists.
if [ -f "${KIND_KUBECONFIG}" ]; then
  rm -f "${KIND_KUBECONFIG}"
  echo "    removed ${KIND_KUBECONFIG}"
fi

echo "==> kind-down: done"
