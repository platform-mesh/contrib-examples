#!/usr/bin/env bash
# hack/cnpg-install.sh — owner: postgres-expert
# Install CloudNativePG into the kind cluster and wait until the controller is ready.
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or kubeconfig paths.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${CNPG_VERSION:?CNPG_VERSION must be set}"

MANIFEST_URL="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"

echo "==> Installing CloudNativePG v${CNPG_VERSION} into kind..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply --server-side -f "${MANIFEST_URL}"

echo "==> Waiting for cnpg-controller-manager rollout (timeout 180s)..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" \
  -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s

echo "==> CloudNativePG v${CNPG_VERSION} ready."
