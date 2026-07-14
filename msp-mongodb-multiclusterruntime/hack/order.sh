#!/usr/bin/env bash
# hack/order.sh — owner: mongodb-expert
# Apply the MongoDBCommunity order into the kcp consumer workspace.
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths or workspace names.
# Idempotent: kubectl apply is a no-op when the resource is already current.
set -euo pipefail

: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

MANIFEST="${TASKFILE_DIR}/config/samples/mongodb.yaml"

export KUBECONFIG="${KCP_ADMIN_KUBECONFIG}"

echo "==> Switching to consumer workspace: ${CONSUMER_WS}"
kubectl ws ":${CONSUMER_WS}"

echo "==> Applying MongoDBCommunity order from ${MANIFEST}..."
kubectl apply -f "${MANIFEST}"

echo "==> Order submitted. MongoDBCommunity 'example-mongodb' is now in workspace ${CONSUMER_WS}."
echo "    The syncher will sync it to kind; watch with:"
echo "    KUBECONFIG=\"\${KCP_ADMIN_KUBECONFIG}\" kubectl ws :${CONSUMER_WS}"
echo "    kubectl -n mongodb get mongodbcommunity example-mongodb -w"
