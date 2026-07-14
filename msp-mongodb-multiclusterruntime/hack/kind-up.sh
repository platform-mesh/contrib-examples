#!/usr/bin/env bash
# hack/kind-up.sh — Create the kind cluster with kcp pre-installed.
# Owner: k8s-expert
#
# This example runs kcp INSIDE the kind cluster (different from msp-postgres-kcp-only).
# The script:
#   1. Creates a kind cluster with port mapping for kcp (8443 -> 31443)
#   2. Installs cert-manager (required by kcp helm chart)
#   3. Installs kcp via helm chart
#   4. Generates the admin kubeconfig
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode values in scripts.
set -euo pipefail

: "${KIND_CLUSTER:?KIND_CLUSTER must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

# Pinned versions
KCP_CHART_VERSION="${KCP_CHART_VERSION:-0.16.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
KCP_HOSTNAME="${KCP_HOSTNAME:-kcp.localhost}"
KCP_EXTERNAL_PORT="${KCP_EXTERNAL_PORT:-8443}"

KIND_CONFIG="${TASKFILE_DIR}/config/kind/cluster.yaml"
KCP_VALUES="${TASKFILE_DIR}/config/kind/kcp-values.yaml"

echodate() {
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"
}

# Ensure kubeconfig directories exist
mkdir -p "$(dirname "${KIND_KUBECONFIG}")"
mkdir -p "$(dirname "${KCP_ADMIN_KUBECONFIG}")"

# --- Create kind cluster ---
echodate "🔍 Checking for kind cluster '${KIND_CLUSTER}'..."
if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
  echodate "⚙️ Creating kind cluster '${KIND_CLUSTER}'..."
  kind create cluster \
    --name "${KIND_CLUSTER}" \
    --config "${KIND_CONFIG}" \
    --kubeconfig "${KIND_KUBECONFIG}"
  echodate "✅ Created kind cluster '${KIND_CLUSTER}'."
else
  echodate "✅ Cluster ${KIND_CLUSTER} already exists."
fi

# Export kubeconfig
kind export kubeconfig --name "${KIND_CLUSTER}" --kubeconfig "${KIND_KUBECONFIG}"
export KUBECONFIG="${KIND_KUBECONFIG}"

# --- Install cert-manager ---
echodate "📥 Adding helm repositories..."
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add kcp https://kcp-dev.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

echodate "⬇️ Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
helm upgrade \
  --install \
  --wait \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  cert-manager jetstack/cert-manager

# --- Install kcp ---
echodate "⚙️ Installing kcp ${KCP_CHART_VERSION}..."
helm upgrade \
  --install \
  --wait \
  --values "${KCP_VALUES}" \
  --namespace kcp \
  --create-namespace \
  --version "${KCP_CHART_VERSION}" \
  --timeout 10m \
  kcp kcp/kcp

# --- Generate admin kubeconfig ---
echodate "🔐 Generating KCP admin kubeconfig..."
cat << EOF > "${KCP_ADMIN_KUBECONFIG}"
apiVersion: v1
kind: Config
clusters:
  - cluster:
      insecure-skip-tls-verify: true
      server: "https://${KCP_HOSTNAME}:${KCP_EXTERNAL_PORT}/clusters/root"
    name: kind-kcp
contexts:
  - context:
      cluster: kind-kcp
      user: kind-kcp
    name: kind-kcp
current-context: kind-kcp
users:
  - name: kind-kcp
    user:
      token: admin-token
EOF

echodate "✅ kind-up complete. kcp is running in-cluster."
