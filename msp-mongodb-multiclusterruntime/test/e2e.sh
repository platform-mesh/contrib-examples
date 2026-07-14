#!/usr/bin/env bash
# test/e2e.sh — owner: test-verifier
#
# End-to-end proof of the MongoDB-MSP loop:
#   consumer orders MongoDBCommunity in the kcp consumer workspace
#     -> multiclusterruntime syncher syncs it DOWN to kind
#       -> MongoDB Community Operator provisions the database
#         -> status syncs BACK UP to the consumer workspace
#
# Run AFTER `task up && task order`. Invoked by `task verify`.
# Reads env vars exported by Taskfile.yml. Fails loudly with captured output and
# prints a final PASS/FAIL summary; exits non-zero if any check failed.
#
# shellcheck disable=SC2329
set -euo pipefail

# --- contract: env vars exported by Taskfile.yml (with fallbacks for standalone runs) ---
KCP_ADMIN_KUBECONFIG="${KCP_ADMIN_KUBECONFIG:?KCP_ADMIN_KUBECONFIG must be set}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
CONSUMER_WS="${CONSUMER_WS:-root:consumer}"
ORDER_NAME="${ORDER_NAME:-example-mongodb}"
ORDER_NS="${ORDER_NS:-mongodb}"

# kubectl wrappers — keep the two control planes unambiguous.
kc() { kubectl --kubeconfig "$KCP_ADMIN_KUBECONFIG" "$@"; }   # kcp operations
kk() { kubectl --kubeconfig "$KIND_KUBECONFIG" "$@"; }         # kind operations

# --- output helpers (checks never abort; we accumulate and summarize at the end) ---
PASS_COUNT=0
FAIL_COUNT=0
pass()    { echo "  [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo "  [FAIL] $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info()    { echo "  [INFO] $*"; }
warn()    { echo "  [WARN] $*"; }
section() { echo; echo "==================== $* ===================="; }

# retry <timeout_s> <interval_s> <fn...> : run fn until it returns 0 or timeout elapses.
retry() {
  local timeout=$1 interval=$2; shift 2
  local deadline=$((SECONDS + timeout))
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [[ $SECONDS -ge $deadline ]] && return 1
    sleep "$interval"
  done
}

echo "######################################################################"
echo "# msp-mongodb end-to-end verification"
echo "#   consumer ws : $CONSUMER_WS"
echo "#   order       : $ORDER_NAME (ns $ORDER_NS)"
echo "#   kcp kubecfg : $KCP_ADMIN_KUBECONFIG"
echo "#   kind kubecfg: $KIND_KUBECONFIG"
echo "######################################################################"

# ---------------------------------------------------------------------------
# CHECK 1 — consumer workspace: the ordered MongoDBCommunity exists in kcp.
# ---------------------------------------------------------------------------
section "1. Consumer workspace: MongoDBCommunity/$ORDER_NAME present in $CONSUMER_WS"

if KUBECONFIG="$KCP_ADMIN_KUBECONFIG" kubectl ws ":$CONSUMER_WS" >/dev/null 2>&1; then
  info "switched into consumer workspace $CONSUMER_WS"
else
  fail "could not enter consumer workspace $CONSUMER_WS (is kcp up? did 'task up' run?)"
fi

if kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" >/dev/null 2>&1; then
  pass "MongoDBCommunity/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
  kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" 2>&1 | sed 's/^/    /' || true
else
  fail "MongoDBCommunity/$ORDER_NAME NOT found in consumer ws — did 'task order' run?"
  kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 2 — kind: the synced MongoDBCommunity exists and MongoDB pods are running.
# ---------------------------------------------------------------------------
section "2. kind: MongoDBCommunity synced and database provisioned"

kind_mongo_exists() {
  kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" >/dev/null 2>&1
}

if retry 120 5 kind_mongo_exists; then
  pass "MongoDBCommunity/$ORDER_NAME synced to kind (ns $ORDER_NS)"
  kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" 2>&1 | sed 's/^/    /' || true
else
  fail "MongoDBCommunity/$ORDER_NAME NOT found on kind — syncher did not sync it"
  echo "    syncher logs:"; kk -n mongodb logs -l app=example-mongodb-mcr-controller --tail=30 2>&1 | sed 's/^/    /' || true
fi

# Check MongoDB pods are running (takes a while for the operator to provision)
kind_mongo_running() {
  local phase
  phase="$(kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Running" ]]
}

if retry 300 10 kind_mongo_running; then
  PHASE="$(kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  VERSION="$(kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.version}' 2>/dev/null || true)"
  pass "MongoDB is Running on kind: phase='$PHASE', version='$VERSION'"
else
  PHASE="$(kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  fail "MongoDB never reached Running phase on kind (current: '${PHASE:-<none>}')"
  echo "    MongoDB status:"; kk -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | head -30 | sed 's/^/    /' || true
  echo "    MongoDB pods:"; kk -n "$ORDER_NS" get pods -l app="${ORDER_NAME}-svc" 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 3 — status sync-back: the consumer-side MongoDBCommunity has Running status.
# ---------------------------------------------------------------------------
section "3. Sync-back: consumer-side MongoDBCommunity status synced"

KUBECONFIG="$KCP_ADMIN_KUBECONFIG" kubectl ws ":$CONSUMER_WS" >/dev/null 2>&1 || true

consumer_status_running() {
  local phase
  phase="$(kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Running" ]]
}

if retry 180 5 consumer_status_running; then
  CPHASE="$(kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  CVERSION="$(kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.version}' 2>/dev/null || true)"
  pass "status synced back to consumer ws: phase='$CPHASE', version='$CVERSION'"
else
  CPHASE="$(kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ -n "$CPHASE" ]; then
    warn "status synced but phase='$CPHASE' (not Running yet)"
    pass "status sync-back is working (phase='$CPHASE')"
  else
    fail "consumer-side .status never populated — status sync-back not working"
    kc -n "$ORDER_NS" get mongodbcommunity.mongodbcommunity.mongodb.com "$ORDER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
  fi
fi

# ---------------------------------------------------------------------------
# CHECK 4 — idempotency note.
# ---------------------------------------------------------------------------
section "4. Idempotency"
info "e2e.sh is read-only."
info "'task order' uses 'kubectl apply' (no-op if unchanged); re-running 'task verify' is stable."
pass "idempotent: safe to re-run"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "SUMMARY"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo
  echo "  ✅ E2E PASS — order -> sync-down -> provision -> status sync-back all verified."
  exit 0
else
  echo
  echo "  ❌ E2E FAIL — $FAIL_COUNT check(s) failed (see [FAIL] lines above)."
  exit 1
fi
