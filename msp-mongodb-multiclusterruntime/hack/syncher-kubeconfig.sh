#!/usr/bin/env bash
# hack/syncher-kubeconfig.sh — owner: syncher-expert
#
# Build the kubeconfig the multiclusterruntime syncher uses to reach kcp's virtual workspace,
# and store it as a Secret on the kind cluster. Idempotent.
#
# The syncher needs a kubeconfig pointing at the virtual workspace URL from the
# APIExportEndpointSlice, not just the admin endpoint.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths/hosts/workspaces.
set -euo pipefail

: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${KCP_CONTROLLER_KUBECONFIG:?KCP_CONTROLLER_KUBECONFIG must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${PROVIDER_WS:?PROVIDER_WS must be set}"

KCP_HOSTNAME="${KCP_HOSTNAME:-kcp.localhost}"

echo "==> Switching to provider workspace and getting VirtualWorkspace URL..."
KUBECONFIG="${KCP_ADMIN_KUBECONFIG}" kubectl ws ":${PROVIDER_WS}" >/dev/null

# Get the virtual workspace URL from the APIExportEndpointSlice
VW_URL="$(KUBECONFIG="${KCP_ADMIN_KUBECONFIG}" kubectl get apiexportendpointslices.apis.kcp.io mongodb -o jsonpath='{.status.endpoints[0].url}' 2>/dev/null || true)"

if [ -z "${VW_URL}" ]; then
  echo "ERROR: Could not get virtual workspace URL from APIExportEndpointSlice 'mongodb'" >&2
  echo "       Make sure 'task kcp:setup' has run successfully." >&2
  exit 1
fi

# In the kind setup, kcp uses a short service name (kcp:<port>); rewrite it
# to include the namespace (kcp.kcp:<port>) so the controller running in
# a different namespace can reach it.
VW_URL="${VW_URL//kcp:/kcp.kcp:}"

echo "    Virtual workspace URL: ${VW_URL}"

# Create the controller kubeconfig pointing at the virtual workspace
echo "==> Generating syncher kubeconfig..."
mkdir -p "$(dirname "${KCP_CONTROLLER_KUBECONFIG}")"
KUBECONFIG="${KCP_ADMIN_KUBECONFIG}" kubectl config view --minify --flatten > "${KCP_CONTROLLER_KUBECONFIG}"
KUBECONFIG="${KCP_CONTROLLER_KUBECONFIG}" kubectl config set-cluster workspace.kcp.io/current \
  --server="${VW_URL}" \
  --insecure-skip-tls-verify=true >/dev/null

# Store as Secret in the mongodb namespace
echo "==> Ensuring namespace mongodb on kind"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create namespace mongodb \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Storing Secret kcp-kubeconfig (key 'kubeconfig') in mongodb namespace"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create secret generic kcp-kubeconfig \
  --namespace mongodb \
  --from-file "kubeconfig=${KCP_CONTROLLER_KUBECONFIG}" \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Done. The syncher will read the kcp kubeconfig from this Secret."
