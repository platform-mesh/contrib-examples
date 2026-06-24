#!/usr/bin/env bash
# hack/syncagent-install.sh — owner: syncagent-expert
# Helm-install (or upgrade) the kcp api-syncagent into the KIND cluster and wait until Ready.
# Idempotent: `helm upgrade --install` converges; the repo add uses --force-update.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or paths:
#   KIND_KUBECONFIG, SYNCAGENT_VERSION, TASKFILE_DIR
#
# Prereq (Taskfile `up` ordering): syncagent:kubeconfig has already created Secret `kcp-kubeconfig`
# in ns kcp-system, which the chart mounts into the agent Pod.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${SYNCAGENT_VERSION:?SYNCAGENT_VERSION must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

VALUES="${TASKFILE_DIR}/config/syncagent/values.yaml"
RELEASE="kcp-api-syncagent"

echo "==> Ensuring kcp Helm repo is present and up to date"
helm repo add kcp https://kcp-dev.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

echo "==> helm upgrade --install ${RELEASE} kcp/api-syncagent --version ${SYNCAGENT_VERSION}"
helm upgrade --install "${RELEASE}" kcp/api-syncagent \
  --version "${SYNCAGENT_VERSION}" \
  --kubeconfig "${KIND_KUBECONFIG}" \
  --namespace kcp-system --create-namespace \
  --values "${VALUES}" \
  --wait --timeout 180s

echo "==> Waiting for the api-syncagent Deployment to be Ready"
kubectl --kubeconfig "${KIND_KUBECONFIG}" -n kcp-system \
  rollout status "deploy/${RELEASE}" --timeout=180s

echo "==> api-syncagent ${SYNCAGENT_VERSION} installed and Ready."
