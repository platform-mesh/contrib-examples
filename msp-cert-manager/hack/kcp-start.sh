#!/usr/bin/env bash
#
# hack/kcp-start.sh — start a local kcp shard, reachable from inside the kind cluster.
# Owner: kcp-expert. LIVE operation — executed by the integration runner (test-verifier), not offline.
#
# Connectivity (the crux of this example):
#   * --bind-address=0.0.0.0 so the host's :6443 is reachable from Docker (kind nodes dial the host).
#   * --shard-base-url / --shard-external-url / --shard-virtual-workspace-url all set to
#     https://$KCP_EXTERNAL_HOST:6443 (host.docker.internal). In kcp v0.31, --shard-base-url sets the
#     apiserver ExternalHost, which (a) lands $KCP_EXTERNAL_HOST in the self-signed serving-cert SANs
#     and (b) makes the APIExportEndpointSlice virtual-workspace URL host.docker.internal-based — which
#     is exactly the URL the api-syncagent (running in kind) follows.
#
# Output: $KCP_KUBECONFIG (.kcp/admin.kubeconfig), rewritten to a HOST-usable address.
# host.docker.internal does not resolve on the macOS host, so every host-side kcp script (and
# syncagent-kubeconfig.sh, which runs `kubectl ws` on the host before swapping the host for the agent
# copy) would break if admin.kubeconfig kept that host. We probe the cert's SAN entries
# (127.0.0.1 → localhost → LAN IP) and pick the first that is both reachable and TLS-valid.
# syncagent-expert builds the in-kind agent's kubeconfig from this file themselves (no extra artifact
# is produced here); kcp advertising host.docker.internal for the virtual-workspace URL is what the
# agent relies on from this script.
#
# We DO NOT override --root-directory/--kubeconfig-path/--cert-dir: their defaults (relative to CWD)
# put state + admin.kubeconfig + certs under .kcp/, which is what Taskfile.yml's env contract expects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKFILE_DIR="${TASKFILE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KCP_BIN="${KCP_BIN:-$TASKFILE_DIR/bin/kcp}"
KCP_KUBECONFIG="${KCP_KUBECONFIG:-$TASKFILE_DIR/.kcp/admin.kubeconfig}"
KCP_EXTERNAL_HOST="${KCP_EXTERNAL_HOST:-host.docker.internal}"
PORT=6443

# Use the version-pinned kcp kubectl plugins from bin/ regardless of what is globally installed.
export PATH="$TASKFILE_DIR/bin:$PATH"

KCP_DIR="$(dirname "$KCP_KUBECONFIG")"   # .../.kcp
LOG="$KCP_DIR/kcp.log"
PIDFILE="$KCP_DIR/kcp.pid"
EXTURL="https://${KCP_EXTERNAL_HOST}:${PORT}"

say() { printf 'kcp-start: %s\n' "$*"; }
die() {
  printf 'kcp-start: ERROR — %s\n' "$*" >&2
  [ -f "$LOG" ] && { printf '----- tail %s -----\n' "$LOG" >&2; tail -n 25 "$LOG" >&2; }
  exit 1
}

command -v "$KCP_BIN" >/dev/null 2>&1 || die "kcp binary not found at $KCP_BIN — run 'task tools:kcp' first"
command -v curl >/dev/null 2>&1 || die "curl is required for the connectivity probe"
command -v yq >/dev/null 2>&1 || die "yq is required to rewrite kubeconfig server URLs"

# Idempotent: if a tracked kcp is already alive, do nothing.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  say "kcp already running (pid $(cat "$PIDFILE")); nothing to do"
  exit 0
fi

mkdir -p "$KCP_DIR"
cd "$TASKFILE_DIR"

say "starting kcp (external host: ${KCP_EXTERNAL_HOST}, bind: 0.0.0.0:${PORT})"
# nohup so the shard survives this script (and the task runner) exiting.
nohup "$KCP_BIN" start \
  --bind-address=0.0.0.0 \
  --shard-base-url="$EXTURL" \
  --shard-external-url="$EXTURL" \
  --shard-virtual-workspace-url="$EXTURL" \
  >"$LOG" 2>&1 &
KCP_PID=$!
echo "$KCP_PID" >"$PIDFILE"
say "kcp pid $KCP_PID, logging to $LOG"

# Wait for kcp to write its admin kubeconfig (or die if the process exits early).
for _ in $(seq 1 90); do
  [ -s "$KCP_KUBECONFIG" ] && break
  kill -0 "$KCP_PID" 2>/dev/null || die "kcp exited before writing $KCP_KUBECONFIG"
  sleep 1
done
[ -s "$KCP_KUBECONFIG" ] || die "timed out waiting for $KCP_KUBECONFIG"

# Extract the CA the kubeconfig trusts, so we can probe candidate host-side addresses against it.
CA_FILE="$KCP_DIR/.probe-ca.crt"
trap 'rm -f "$CA_FILE"' EXIT
ca_data="$(yq -r '.clusters[0].cluster."certificate-authority-data" // ""' "$KCP_KUBECONFIG")"
if [ -n "$ca_data" ] && [ "$ca_data" != "null" ]; then
  printf '%s' "$ca_data" | base64 -d >"$CA_FILE"
else
  ca_path="$(yq -r '.clusters[0].cluster."certificate-authority" // ""' "$KCP_KUBECONFIG")"
  [ -n "$ca_path" ] || die "could not find a CA in $KCP_KUBECONFIG"
  case "$ca_path" in /*) : ;; *) ca_path="$KCP_DIR/$ca_path" ;; esac
  cp "$ca_path" "$CA_FILE"
fi

# A host candidate is good if the TLS cert validates for it (SAN match) AND it is reachable.
# curl returns 0 on any HTTP response (incl. 401/403); nonzero on cert mismatch / connection refused.
probe() { curl -sS -o /dev/null --cacert "$CA_FILE" "https://$1:${PORT}/readyz" >/dev/null 2>&1; }

HOST_ADDR=""
candidates=(127.0.0.1 localhost)
lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
[ -n "$lan_ip" ] && candidates+=("$lan_ip")
say "probing host-usable addresses: ${candidates[*]}"
for _ in $(seq 1 90); do
  for h in "${candidates[@]}"; do
    if probe "$h"; then HOST_ADDR="$h"; break; fi
  done
  [ -n "$HOST_ADDR" ] && break
  kill -0 "$KCP_PID" 2>/dev/null || die "kcp exited during readiness probe"
  sleep 1
done
[ -n "$HOST_ADDR" ] || die "no reachable + TLS-valid host address found among ${candidates[*]}; inspect serving-cert SANs under $KCP_DIR"
say "host-usable address: $HOST_ADDR"

# Advisory canary: is the serving cert valid for $KCP_EXTERNAL_HOST? We can't rely on
# host.docker.internal resolving on the host, so we map it to the loopback with curl --resolve, which
# still drives SNI + cert verification against the $KCP_EXTERNAL_HOST name. The in-kind agent connects
# with --insecure-skip-tls-verify (see syncagent-kubeconfig.sh), so a missing SAN does NOT break the
# demo — but a failure here is a useful signal that --shard-base-url=${EXTURL} did not take effect
# (which would also affect what kcp advertises as the virtual-workspace URL). Warn, do not fail.
if curl -sS -o /dev/null --resolve "${KCP_EXTERNAL_HOST}:${PORT}:127.0.0.1" --cacert "$CA_FILE" \
      "https://${KCP_EXTERNAL_HOST}:${PORT}/readyz" >/dev/null 2>&1; then
  say "serving cert is valid for ${KCP_EXTERNAL_HOST} (kcp is advertising the external host)"
else
  say "NOTE: serving cert is not valid for ${KCP_EXTERNAL_HOST} (tolerated — the agent uses insecure-skip-tls-verify). Confirm the APIExportEndpointSlice virtual-workspace URL still uses ${KCP_EXTERNAL_HOST}."
fi

# Rewrite the admin kubeconfig's authority to the chosen host address (preserves any /clusters path).
yq -i "(.clusters[].cluster.server) |= sub(\"//[^/]+\"; \"//${HOST_ADDR}:${PORT}\")" "$KCP_KUBECONFIG"

# Final readiness gate. `get apiexports` alone returns BEFORE kcp registers the tenancy Workspace
# path, so a fresh `kubectl ws create` then 404s with "could not find the requested resource (post
# workspaces.tenancy.kcp.io)". Gate on BOTH apiexports AND the tenancy Workspace resource being served
# so kcp-workspaces.sh doesn't race kcp's discovery/bootstrap on a cold start (kcp-workspaces.sh also
# retries create as a belt-and-suspenders).
for _ in $(seq 1 120); do
  if kubectl --kubeconfig "$KCP_KUBECONFIG" get apiexports >/dev/null 2>&1 &&
    kubectl --kubeconfig "$KCP_KUBECONFIG" get workspaces.tenancy.kcp.io >/dev/null 2>&1; then
    say "kcp is up: server https://${HOST_ADDR}:${PORT} (host) / ${EXTURL} (agent + virtual workspace)"
    exit 0
  fi
  kill -0 "$KCP_PID" 2>/dev/null || die "kcp exited before becoming ready"
  sleep 1
done
die "kcp API did not become ready (apiexports + workspaces.tenancy.kcp.io not both served)"
