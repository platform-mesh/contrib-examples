#!/usr/bin/env bash
# hack/mongodb-operator-install.sh — owner: mongodb-expert
# Install MongoDB Community Operator into the kind cluster and wait until ready.
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or kubeconfig paths.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${MONGODB_OPERATOR_VERSION:?MONGODB_OPERATOR_VERSION must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

MONGO_SECRET="${TASKFILE_DIR}/config/mongodb-operator/mongo-secret.yaml"

export KUBECONFIG="${KIND_KUBECONFIG}"

echo "==> Adding MongoDB helm repo..."
helm repo add mongodb https://mongodb.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

echo "==> Installing MongoDB Community Operator v${MONGODB_OPERATOR_VERSION} into kind..."
helm upgrade \
  --install \
  --wait \
  --namespace mongodb \
  --create-namespace \
  --version "${MONGODB_OPERATOR_VERSION}" \
  mongodb mongodb/community-operator

echo "==> Applying MongoDB secret..."
kubectl apply -f "${MONGO_SECRET}"

echo "==> Waiting for MongoDB Operator rollout (timeout 180s)..."
kubectl -n mongodb rollout status deploy/mongodb-kubernetes-operator --timeout=180s

echo "==> MongoDB Community Operator v${MONGODB_OPERATOR_VERSION} ready."
