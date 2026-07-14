#!/usr/bin/env bash
# hack/httpbin-operator-install.sh — owner: httpbin-expert
# Install the httpbin-operator into the kind cluster and wait until the controller is ready.
# Reads env vars exported by Taskfile.yml; do NOT hardcode versions or kubeconfig paths.
#
# The httpbin-operator provides the HttpBin CRD and controller. When an HttpBin CR is created,
# the operator creates a Deployment + Service running the httpbin container.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${HTTPBIN_OPERATOR_IMAGE:?HTTPBIN_OPERATOR_IMAGE must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

MANIFESTS_DIR="${TASKFILE_DIR}/config/httpbin-operator"
NAMESPACE="httpbin-system"

echo "==> Installing httpbin-operator CRDs..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f "${MANIFESTS_DIR}/crds.yaml"

echo "==> Creating namespace ${NAMESPACE}..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Installing httpbin-operator deployment..."
# Substitute the image in the deployment manifest
sed "s|IMAGE_PLACEHOLDER|${HTTPBIN_OPERATOR_IMAGE}|g" "${MANIFESTS_DIR}/deployment.yaml" \
  | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Waiting for httpbin-operator-controller-manager rollout (timeout 180s)..."
kubectl --kubeconfig "${KIND_KUBECONFIG}" \
  -n "${NAMESPACE}" rollout status deploy/httpbin-operator-controller-manager --timeout=180s

echo "==> httpbin-operator ready."
