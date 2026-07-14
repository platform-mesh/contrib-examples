#!/usr/bin/env bash
# hack/provider-bind.sh — bind the consumer workspace to the provider's mongodb APIExport.
# Owner: kcp-expert.
#
# Enters $CONSUMER_WS, applies config/kcp/apibinding.yaml, waits for the APIBinding to reach phase
# Bound, then creates the mongodb namespace and asserts MongoDBCommunity API is served.
#
# NOTE: this depends on the provider workspace having the APIExport ready (task kcp:setup).
set -euo pipefail

: "${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
: "${PROVIDER_WS:?PROVIDER_WS must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${ORDER_NS:?ORDER_NS must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

APIBINDING_MANIFEST="${TASKFILE_DIR}/config/kcp/apibinding.yaml"

export KUBECONFIG="${KCP_ADMIN_KUBECONFIG}"

say() { printf 'provider-bind: %s\n' "$*"; }
die() { printf 'provider-bind: ERROR — %s\n' "$*" >&2; exit 1; }

[ -s "${KCP_ADMIN_KUBECONFIG}" ] || die "kcp kubeconfig not found at ${KCP_ADMIN_KUBECONFIG} — run 'task kind:up' first"
[ -f "${APIBINDING_MANIFEST}" ] || die "missing ${APIBINDING_MANIFEST}"

say "entering consumer workspace: ${CONSUMER_WS}"
kubectl ws ":${CONSUMER_WS}" >/dev/null || die "could not enter ${CONSUMER_WS} — run 'task kcp:setup' first"

say "applying APIBinding -> ${PROVIDER_WS}"
kubectl apply -f "${APIBINDING_MANIFEST}"

say "waiting for APIBinding to reach phase Bound"
bound=""
for _ in $(seq 1 120); do
  phase="$(kubectl get apibinding mongodb -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" = "Bound" ]; then bound=1; break; fi
  sleep 1
done
if [ -z "$bound" ]; then
  kubectl get apibinding mongodb -o yaml 2>/dev/null | sed -n '/status:/,$p' >&2 || true
  die "APIBinding 'mongodb' did not reach Bound (last phase: '${phase:-<none>}')"
fi
say "APIBinding 'mongodb' is Bound"

# Create the namespace for MongoDB orders
say "creating namespace ${ORDER_NS} in consumer workspace"
kubectl create namespace "${ORDER_NS}" --dry-run=client -o yaml | kubectl apply -f -

# Assert the MongoDB API is now served in the consumer workspace.
say "asserting mongodbcommunity.mongodbcommunity.mongodb.com is served in ${CONSUMER_WS}"
served=""
for _ in $(seq 1 30); do
  if kubectl api-resources --api-group=mongodbcommunity.mongodb.com 2>/dev/null | grep -qw mongodbcommunity; then
    served=1
    break
  fi
  sleep 1
done
[ -n "$served" ] || die "mongodbcommunity API is not served in ${CONSUMER_WS}"

say "done: ${CONSUMER_WS} can now order MongoDBCommunity resources"
