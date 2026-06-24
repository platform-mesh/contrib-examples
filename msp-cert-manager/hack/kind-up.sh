#!/usr/bin/env bash
# hack/kind-up.sh — Create the kind cluster (idempotent).
# Owner: k8s-expert
#
# Reads env vars exported by Taskfile.yml:
#   KIND_CLUSTER, KIND_KUBECONFIG, TASKFILE_DIR
set -euo pipefail

: "${KIND_CLUSTER:?KIND_CLUSTER must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

CLUSTER_CONFIG="${TASKFILE_DIR}/config/kind/cluster.yaml"

echo "==> kind-up: cluster='${KIND_CLUSTER}'"

# Ensure the kubeconfig directory exists BEFORE kind create so we can pass
# --kubeconfig and prevent kind from inheriting KUBECONFIG=.kcp/admin.kubeconfig
# (which would merge kind entries into the kcp admin kubeconfig and corrupt it).
mkdir -p "$(dirname "${KIND_KUBECONFIG}")"

# Create cluster only if it doesn't already exist.
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
  echo "    cluster '${KIND_CLUSTER}' already exists — skipping create"
else
  echo "    creating cluster from ${CLUSTER_CONFIG}"
  kind create cluster \
    --name "${KIND_CLUSTER}" \
    --config "${CLUSTER_CONFIG}" \
    --kubeconfig "${KIND_KUBECONFIG}"
fi

# Export the kubeconfig (overwrites if already present; idempotent).
echo "==> Exporting kubeconfig to ${KIND_KUBECONFIG}"
kind export kubeconfig \
  --name "${KIND_CLUSTER}" \
  --kubeconfig "${KIND_KUBECONFIG}"

# Quick sanity check — must use explicit --kubeconfig for kind ops.
echo "==> Verifying cluster nodes"
kubectl --kubeconfig "${KIND_KUBECONFIG}" get nodes

echo "==> kind-up: done"
