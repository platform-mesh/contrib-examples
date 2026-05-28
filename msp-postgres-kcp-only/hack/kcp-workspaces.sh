#!/usr/bin/env bash
#
# hack/kcp-workspaces.sh — create the workspace tree and seed the provider's empty APIExport.
# Owner: kcp-expert. LIVE operation (executed by the integration runner).
#
# Creates (idempotently): the org ws (root:msp), the provider ws ($PROVIDER_WS) and the consumer ws
# ($CONSUMER_WS), then applies config/kcp/apiexport.yaml inside the provider ws. The intermediate org
# segment is derived by walking each absolute $PROVIDER_WS / $CONSUMER_WS path, so nothing is hardcoded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKFILE_DIR="${TASKFILE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KCP_KUBECONFIG="${KCP_KUBECONFIG:-$TASKFILE_DIR/.kcp/admin.kubeconfig}"
PROVIDER_WS="${PROVIDER_WS:-root:msp:postgres-provider}"
CONSUMER_WS="${CONSUMER_WS:-root:msp:customer-a}"
APIEXPORT_MANIFEST="$TASKFILE_DIR/config/kcp/apiexport.yaml"

# kcp ws / kubectl plugins come from the version-pinned bin/.
export PATH="$TASKFILE_DIR/bin:$PATH"
export KUBECONFIG="$KCP_KUBECONFIG"

say() { printf 'kcp-workspaces: %s\n' "$*"; }
die() { printf 'kcp-workspaces: ERROR — %s\n' "$*" >&2; exit 1; }

[ -s "$KCP_KUBECONFIG" ] || die "kcp kubeconfig not found at $KCP_KUBECONFIG — run 'task kcp:start' first"
kubectl ws . >/dev/null 2>&1 || die "kubectl ws plugin not working or kcp not reachable via $KCP_KUBECONFIG"
[ -f "$APIEXPORT_MANIFEST" ] || die "missing $APIEXPORT_MANIFEST"

# ws_retry <kubectl-ws-args...> — run `kubectl ws <args>`, retrying through the brief cold-start
# window where kcp's tenancy Workspace path / WorkspaceType defaults / controller caches aren't ready
# yet (kcp's apiexports readiness can precede them; symptom: "could not find the requested resource
# (post workspaces.tenancy.kcp.io)", or a just-created ws still Initializing). Only known transients
# retry; a genuine error surfaces immediately. ~120s budget per call.
ws_retry() {
  local out i
  for i in $(seq 1 60); do
    if out="$(kubectl ws "$@" 2>&1)"; then
      return 0
    fi
    case "$out" in
      *"could not find the requested resource"*) sleep 2 ;;
      *"the server is currently unable"*) sleep 2 ;;
      *"no matches for kind"*) sleep 2 ;;
      *"connection refused"*) sleep 2 ;;
      *"i/o timeout"*) sleep 2 ;;
      *"EOF"*) sleep 2 ;;
      *"not ready"* | *"NotReady"* | *"Initializing"*) sleep 2 ;;
      *)
        printf 'kcp-workspaces: kubectl ws %s failed: %s\n' "$*" "$out" >&2
        return 1
        ;;
    esac
  done
  printf 'kcp-workspaces: kubectl ws %s kept failing (last: %s)\n' "$*" "$out" >&2
  return 1
}

# ensure_ws <absolute-path like root:msp:postgres-provider>
# Walks from root, creating each segment if absent, and leaves the current context inside <path>.
ensure_ws() {
  local full="$1"
  case "$full" in
    root | root:*) : ;;
    *) die "workspace path must be absolute under root: '$full'" ;;
  esac
  ws_retry ":root"
  local acc="root" seg
  IFS=':' read -r -a parts <<<"$full"
  for ((i = 1; i < ${#parts[@]}; i++)); do
    seg="${parts[i]}"
    # --ignore-existing = create-if-absent; default type (no --type) matches a vanilla kcp shard.
    ws_retry create "$seg" --ignore-existing
    acc="${acc}:${seg}"
    ws_retry ":${acc}"
  done
}

say "ensuring provider workspace: $PROVIDER_WS"
ensure_ws "$PROVIDER_WS"   # leaves the current context inside the provider ws
say "applying empty APIExport into $PROVIDER_WS"
kubectl apply -f "$APIEXPORT_MANIFEST"

say "ensuring consumer workspace: $CONSUMER_WS"
ensure_ws "$CONSUMER_WS"

# Leave the context somewhere predictable (root) so later scripts start from a known place.
kubectl ws ":root" >/dev/null

say "done: $PROVIDER_WS (APIExport api-syncagent) + $CONSUMER_WS ready"
