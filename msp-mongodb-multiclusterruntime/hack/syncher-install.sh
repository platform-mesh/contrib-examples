#!/usr/bin/env bash
# hack/syncher-install.sh — owner: syncher-expert
# Deploy the multiclusterruntime syncher into the kind cluster and wait until Ready.
# Idempotent: kubectl apply converges.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or paths.
#
# Prereq (Taskfile `up` ordering): syncher:kubeconfig has already created Secret `kcp-kubeconfig`
# in ns mongodb, which the deployment mounts into the syncher Pod.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${SYNCHER_IMAGE:?SYNCHER_IMAGE must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

DEPLOYMENT="${TASKFILE_DIR}/config/syncher/deployment.yaml"

export KUBECONFIG="${KIND_KUBECONFIG}"

echo "==> Installing multiclusterruntime syncher..."
# Substitute the image placeholder
sed "s|IMAGE_PLACEHOLDER|${SYNCHER_IMAGE}|g" "${DEPLOYMENT}" \
  | kubectl apply -f -

echo "==> Waiting for syncher rollout (timeout 180s)..."
kubectl -n mongodb rollout status deploy/example-mongodb-mcr-controller --timeout=180s

echo "==> multiclusterruntime syncher installed and Ready."
