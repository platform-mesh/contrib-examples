#!/usr/bin/env bash
# hack/certmanager-install.sh — owner: cert-manager-expert
# Install cert-manager into the kind cluster, wait until the controller is ready, then apply
# the self-signed ClusterIssuer used by the RGD. Idempotent (apply).
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or kubeconfig paths:
#   KIND_KUBECONFIG, CERTMANAGER_VERSION, TASKFILE_DIR
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${CERTMANAGER_VERSION:?CERTMANAGER_VERSION must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

MANIFEST_URL="https://github.com/cert-manager/cert-manager/releases/download/v${CERTMANAGER_VERSION}/cert-manager.yaml"
ISSUER_MANIFEST="${TASKFILE_DIR}/config/cert-manager/issuer.yaml"
RGD_MANIFEST="${TASKFILE_DIR}/config/cert-manager/rgd.yaml"

echo "==> Installing cert-manager v${CERTMANAGER_VERSION} into kind..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply --server-side -f "${MANIFEST_URL}"

echo "==> Waiting for cert-manager webhook rollout (timeout 180s)..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" \
  -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

echo "==> Waiting for cert-manager controller rollout (timeout 180s)..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" \
  -n cert-manager rollout status deploy/cert-manager --timeout=180s

echo "==> Waiting for cert-manager to be fully ready (CRD establishment)..."
# The webhook needs a moment to accept requests before we can apply the ClusterIssuer.
# Retry the ClusterIssuer apply until it succeeds (cert-manager webhook initializing).
for i in $(seq 1 30); do
  if kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f "${ISSUER_MANIFEST}" 2>/dev/null; then
    echo "    ClusterIssuer applied"
    break
  fi
  echo "    waiting for cert-manager webhook to be ready... (${i}/30)"
  sleep 5
done

echo "==> Applying KRO ResourceGraphDefinition for certmanager.ca/Certificate..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f "${RGD_MANIFEST}"

echo "==> Waiting for RGD certificates.certmanager.ca to become Active (timeout 120s)..."
state=""
deadline=$((SECONDS + 120))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  state="$(kubectl --kubeconfig "${KIND_KUBECONFIG}" \
    get resourcegraphdefinition.kro.run/certificates.certmanager.ca \
    -o jsonpath='{.status.state}' 2>/dev/null || true)"
  if [ "${state}" = "Active" ]; then
    echo "    RGD Active — certmanager.ca/v1alpha1/Certificate CRD is registered"
    break
  fi
  sleep 3
done
if [ "${state}" != "Active" ]; then
  echo "WARNING: RGD certificates.certmanager.ca not Active after 120s — kro may still be starting." >&2
  echo "         If task syncagent:publish fails later, inspect kro logs:" >&2
  echo "         kubectl --kubeconfig \"\${KIND_KUBECONFIG}\" -n kro-system logs -l app.kubernetes.io/name=kro --tail=50" >&2
fi

echo "==> cert-manager v${CERTMANAGER_VERSION} ready."
