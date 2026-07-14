#!/usr/bin/env bash
# hack/order.sh — owner: httpbin-expert
# Apply the HttpBin order into the kcp consumer workspace.
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths or workspace names.
# Idempotent: kubectl apply is a no-op when the resource is already current.
set -euo pipefail

: "${KCP_KUBECONFIG:?KCP_KUBECONFIG must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

# Use the pinned kcp kubectl-ws plugin from bin/ (same pattern as kcp-workspaces.sh).
export PATH="${TASKFILE_DIR}/bin:${PATH}"

MANIFEST="${TASKFILE_DIR}/config/samples/order-httpbin.yaml"

echo "==> Switching to consumer workspace: ${CONSUMER_WS}"
# kubectl-ws is a plugin; flags cannot precede the plugin name — pass kubeconfig via env.
KUBECONFIG="${KCP_KUBECONFIG}" kubectl ws "${CONSUMER_WS}"

echo "==> Applying HttpBin order from ${MANIFEST}..."
kubectl --kubeconfig "${KCP_KUBECONFIG}" apply -f "${MANIFEST}"

echo "==> Order submitted. HttpBin 'httpbin-demo' is now in workspace ${CONSUMER_WS}."
echo "    api-syncagent will sync it to kind; watch with:"
echo "    kubectl --kubeconfig \"\${KCP_KUBECONFIG}\" get httpbin httpbin-demo -n default -w"
