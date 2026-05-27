#!/usr/bin/env bash
#
# hack/provider-bind.sh — bind the consumer workspace to the provider's api-syncagent APIExport.
# Owner: kcp-expert. LIVE operation (executed by the integration runner).
#
# Enters $CONSUMER_WS, applies config/kcp/apibinding.yaml, waits for the APIBinding to reach phase
# Bound, then asserts that clusters.postgresql.cnpg.io is served natively in the consumer workspace.
#
# NOTE: this depends on the api-syncagent having already published the CNPG Cluster API into the
# provider APIExport (task syncagent:publish). In `task up` that runs before provider:bind, so the
# export carries the schema by the time we bind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKFILE_DIR="${TASKFILE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KCP_KUBECONFIG="${KCP_KUBECONFIG:-$TASKFILE_DIR/.kcp/admin.kubeconfig}"
PROVIDER_WS="${PROVIDER_WS:-root:msp:postgres-provider}"
CONSUMER_WS="${CONSUMER_WS:-root:msp:customer-a}"
APIBINDING_MANIFEST="$TASKFILE_DIR/config/kcp/apibinding.yaml"

BINDING_NAME="api-syncagent"
CNPG_RESOURCE="clusters.postgresql.cnpg.io"

export PATH="$TASKFILE_DIR/bin:$PATH"
export KUBECONFIG="$KCP_KUBECONFIG"

say() { printf 'provider-bind: %s\n' "$*"; }
die() { printf 'provider-bind: ERROR — %s\n' "$*" >&2; exit 1; }

[ -s "$KCP_KUBECONFIG" ] || die "kcp kubeconfig not found at $KCP_KUBECONFIG — run 'task kcp:start' first"
[ -f "$APIBINDING_MANIFEST" ] || die "missing $APIBINDING_MANIFEST"

# Guard: the manifest's export path must equal $PROVIDER_WS, else the binding can never bind.
manifest_path="$(yq -r '.spec.reference.export.path' "$APIBINDING_MANIFEST")"
[ "$manifest_path" = "$PROVIDER_WS" ] || die "apibinding.yaml export path '$manifest_path' != PROVIDER_WS '$PROVIDER_WS' (fix the manifest or the Taskfile var)"

say "entering consumer workspace: $CONSUMER_WS"
kubectl ws ":$CONSUMER_WS" >/dev/null || die "could not enter $CONSUMER_WS — run 'task kcp:workspaces' first"

say "applying APIBinding '$BINDING_NAME' -> $PROVIDER_WS"
kubectl apply -f "$APIBINDING_MANIFEST"

say "waiting for APIBinding/$BINDING_NAME to reach phase Bound"
bound=""
for _ in $(seq 1 120); do
  phase="$(kubectl get apibinding "$BINDING_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" = "Bound" ]; then bound=1; break; fi
  sleep 1
done
if [ -z "$bound" ]; then
  kubectl get apibinding "$BINDING_NAME" -o yaml 2>/dev/null | sed -n '/status:/,$p' >&2 || true
  die "APIBinding/$BINDING_NAME did not reach Bound (last phase: '${phase:-<none>}')"
fi
say "APIBinding/$BINDING_NAME is Bound"

# Assert the CNPG Cluster API is now served in the consumer workspace.
say "asserting $CNPG_RESOURCE is served in $CONSUMER_WS"
served=""
for _ in $(seq 1 30); do
  if kubectl api-resources --api-group=postgresql.cnpg.io 2>/dev/null | grep -qw clusters; then served=1; break; fi
  sleep 1
done
[ -n "$served" ] || die "$CNPG_RESOURCE is not served in $CONSUMER_WS (did task syncagent:publish populate the APIExport?)"

say "done: $CONSUMER_WS can now order $CNPG_RESOURCE"
