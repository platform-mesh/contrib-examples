#!/usr/bin/env bash
# hack/kcp-setup.sh — Wait for kcp, create workspaces, apply APIResourceSchema + APIExport.
# Owner: kcp-expert
#
# Creates (idempotently):
#   - Provider workspace (root:mongodb) with APIResourceSchema + APIExport
#   - Consumer workspace (root:consumer)
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode values in scripts.
set -euo pipefail

: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${PROVIDER_WS:?PROVIDER_WS must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

MONGO_API_MANIFEST="${TASKFILE_DIR}/config/kcp/mongo-api.yaml"

export KUBECONFIG="${KCP_ADMIN_KUBECONFIG}"

say() { printf 'kcp-setup: %s\n' "$*"; }
die() { printf 'kcp-setup: ERROR — %s\n' "$*" >&2; exit 1; }

[ -s "${KCP_ADMIN_KUBECONFIG}" ] || die "kcp admin kubeconfig not found at ${KCP_ADMIN_KUBECONFIG} — run 'task kind:up' first"
[ -f "${MONGO_API_MANIFEST}" ] || die "missing ${MONGO_API_MANIFEST}"

# Wait for kcp to be ready
say "waiting for kcp to be ready..."
for _ in $(seq 1 120); do
  if kubectl get workspaces.tenancy.kcp.io >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl get workspaces.tenancy.kcp.io >/dev/null 2>&1 || die "kcp not ready after 240s"
say "kcp is ready"

# Extract workspace names from paths like root:mongodb -> mongodb
provider_name="${PROVIDER_WS##*:}"
consumer_name="${CONSUMER_WS##*:}"

# Create provider workspace
say "ensuring provider workspace: ${PROVIDER_WS}"
if ! kubectl get workspace "${provider_name}" >/dev/null 2>&1; then
  kubectl create workspace "${provider_name}"
fi
kubectl ws ":${PROVIDER_WS}" >/dev/null

# Apply APIResourceSchema + APIExport
say "applying APIResourceSchema + APIExport into ${PROVIDER_WS}"
kubectl apply -f "${MONGO_API_MANIFEST}"

# Create consumer workspace
say "ensuring consumer workspace: ${CONSUMER_WS}"
kubectl ws ":root" >/dev/null
if ! kubectl get workspace "${consumer_name}" >/dev/null 2>&1; then
  kubectl create workspace "${consumer_name}"
fi

say "done: ${PROVIDER_WS} (APIExport mongodb) + ${CONSUMER_WS} ready"
