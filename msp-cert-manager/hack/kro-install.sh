#!/usr/bin/env bash
# hack/kro-install.sh — owner: cert-manager-expert
# Install kro (Kubernetes Resource Orchestrator) into the kind cluster and wait until ready.
# kro is used to translate certmanager.ca/Certificate into cert-manager.io/Certificate via
# the ResourceGraphDefinition in config/cert-manager/rgd.yaml.
# Idempotent: helm upgrade --install converges on re-runs.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or kubeconfig paths:
#   KIND_KUBECONFIG, KRO_VERSION, TASKFILE_DIR
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${KRO_VERSION:?KRO_VERSION must be set}"

RELEASE="kro"
NAMESPACE="kro-system"

# kro is distributed as an OCI Helm chart (no traditional Helm repo index).
echo "==> helm upgrade --install ${RELEASE} oci://ghcr.io/kro-run/kro/kro --version ${KRO_VERSION}"
helm upgrade --install "${RELEASE}" oci://ghcr.io/kro-run/kro/kro \
  --version "${KRO_VERSION}" \
  --kubeconfig "${KIND_KUBECONFIG}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --wait --timeout 180s

echo "==> Waiting for kro controller Deployment to be Ready"
kubectl --kubeconfig "${KIND_KUBECONFIG}" -n "${NAMESPACE}" \
  rollout status "deploy/kro" --timeout=120s

echo "==> kro ${KRO_VERSION} installed and Ready."
