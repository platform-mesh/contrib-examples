#!/usr/bin/env bash
#
# hack/kcp-stop.sh — stop the local kcp shard started by hack/kcp-start.sh. Idempotent.
# Owner: kcp-expert.
#
#   hack/kcp-stop.sh            stop the process (no-op if not running)
#   hack/kcp-stop.sh --purge    stop, then delete .kcp/ (state, certs, kubeconfigs, logs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKFILE_DIR="${TASKFILE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KCP_KUBECONFIG="${KCP_KUBECONFIG:-$TASKFILE_DIR/.kcp/admin.kubeconfig}"
KCP_DIR="$(dirname "$KCP_KUBECONFIG")"
PIDFILE="$KCP_DIR/kcp.pid"

PURGE=0
case "${1:-}" in
  --purge) PURGE=1 ;;
  "") : ;;
  *)
    echo "kcp-stop: unknown argument '$1' (expected --purge or nothing)" >&2
    exit 2
    ;;
esac

say() { printf 'kcp-stop: %s\n' "$*"; }

if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    say "stopping kcp (pid $pid)"
    kill "$pid" 2>/dev/null || true
    # Give it up to ~10s to exit cleanly, then force-kill.
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      say "kcp still alive; sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    say "no live kcp for pid '${pid:-<empty>}' (stale pidfile)"
  fi
  rm -f "$PIDFILE"
else
  say "no pidfile at $PIDFILE; nothing to stop"
fi

if [ "$PURGE" -eq 1 ]; then
  say "purging $KCP_DIR"
  rm -rf "$KCP_DIR"
fi

say "done"
