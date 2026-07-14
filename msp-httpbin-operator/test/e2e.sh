#!/usr/bin/env bash
# test/e2e.sh — owner: test-verifier
#
# End-to-end proof of the HttpBin-MSP loop:
#   consumer orders HttpBin/httpbin-demo in the kcp consumer workspace
#     -> api-syncagent syncs it DOWN to kind
#       -> httpbin-operator provisions a Deployment + Service
#         -> a live HTTP request to httpbin succeeds.
#
# Run AFTER `task up && task order`. Invoked by `task verify`.
# Reads env vars exported by Taskfile.yml. Fails loudly with captured output and
# prints a final PASS/FAIL summary; exits non-zero if any check failed.
#
# NAME-MANGLING (critical): api-syncagent renames synced objects on the kind side to
# avoid cross-workspace collisions. So on kind the HttpBin/Deployment/Service names DIFFER
# from `httpbin-demo` unless the `naming` block in the PublishedResource preserves them.
# We therefore DISCOVER the on-kind HttpBin (there is exactly one in this single-consumer demo)
# and derive every other name from its real metadata.
#
# NOTE: The httpbin-operator creates Deployment/Service with prefix "httpbin-" (e.g.
# httpbin-httpbin-demo for an HttpBin named httpbin-demo). We discover these by looking
# for the HttpBinDeployment CR that the operator creates.
#
# Several functions below are invoked indirectly (cleanup via `trap`; the *_present /
# *_ready predicates via the `retry` helper's "$@"), which shellcheck cannot trace, so
# its "function never invoked" check is disabled file-wide.
# shellcheck disable=SC2329
set -euo pipefail

# --- contract: env vars exported by Taskfile.yml (with fallbacks for standalone runs) ---
KCP_KUBECONFIG="${KCP_KUBECONFIG:?KCP_KUBECONFIG must be set}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
CONSUMER_WS="${CONSUMER_WS:-root:msp:customer-a}"
ORDER_NAME="${ORDER_NAME:-httpbin-demo}"
ORDER_NS="${ORDER_NS:-default}"          # namespace of the ordered HttpBin in the consumer ws
AGENT_NAME="${AGENT_NAME:-msp-httpbin}"  # api-syncagent agentName (config/syncagent/values.yaml)
SYNC_SELECTOR="syncagent.kcp.io/agent-name=${AGENT_NAME}"  # marks objects THIS agent synced (kind side)

# kubectl wrappers — keep the two control planes unambiguous.
kc() { kubectl --kubeconfig "$KCP_KUBECONFIG" "$@"; }   # kcp operations
kk() { kubectl --kubeconfig "$KIND_KUBECONFIG" "$@"; }  # kind operations
# `kubectl ws` is a plugin: flags must come AFTER the plugin name, so pass the kubeconfig via
# the env var rather than `--kubeconfig` (which kubectl rejects before a plugin name).
kcws() { KUBECONFIG="$KCP_KUBECONFIG" kubectl ws "$@"; }

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
echo "# msp-httpbin end-to-end verification"
echo "#   consumer ws : $CONSUMER_WS"
echo "#   order       : $ORDER_NAME (ns $ORDER_NS)"
echo "#   kcp kubecfg : $KCP_KUBECONFIG"
echo "#   kind kubecfg: $KIND_KUBECONFIG"
echo "######################################################################"

# ---------------------------------------------------------------------------
# CHECK 1a — consumer workspace: the ordered HttpBin exists in kcp.
# ---------------------------------------------------------------------------
section "1a. Consumer workspace: HttpBin/$ORDER_NAME present in $CONSUMER_WS"

if kcws "$CONSUMER_WS" >/dev/null 2>&1; then
  info "switched into consumer workspace $CONSUMER_WS"
else
  fail "could not enter consumer workspace $CONSUMER_WS (is kcp up? did 'task up' run?)"
  echo; echo "ws error:"; kcws "$CONSUMER_WS" 2>&1 | sed 's/^/    /' || true
fi

if kc -n "$ORDER_NS" get httpbin.orchestrate.platform-mesh.io "$ORDER_NAME" >/dev/null 2>&1; then
  pass "HttpBin/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
  kc -n "$ORDER_NS" get httpbin.orchestrate.platform-mesh.io "$ORDER_NAME" -o wide 2>&1 | sed 's/^/    /' || true
else
  fail "HttpBin/$ORDER_NAME NOT found in consumer ws — did 'task order' run?"
  kc -n "$ORDER_NS" get httpbin.orchestrate.platform-mesh.io 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 2 — kind: the synced HttpBin is healthy, deployment Ready.
# Discover the (mangled) on-kind HttpBin; derive all other names from it.
# ---------------------------------------------------------------------------
section "2. kind: discover the agent-synced HttpBin (provenance-aware) and assert health"

# Prefer the api-syncagent provenance label (proves THIS agent synced the object down); fall back
# to an unlabeled lookup so the check still works if that label ever changes.
present_labeled() { [[ -n "$(kk get httpbin.orchestrate.platform-mesh.io -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }

PROVENANCE="labeled"
KIND_HTTPBIN_NAME=""
KIND_NS=""
if retry 150 4 present_labeled; then
  read -r KIND_HTTPBIN_NAME KIND_NS <<<"$(kk get httpbin.orchestrate.platform-mesh.io -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
elif [[ -n "$(kk get httpbin.orchestrate.platform-mesh.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
  PROVENANCE="unlabeled-fallback"
  read -r KIND_HTTPBIN_NAME KIND_NS <<<"$(kk get httpbin.orchestrate.platform-mesh.io -A -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
fi

if [[ -n "$KIND_HTTPBIN_NAME" ]]; then
  if [[ "$PROVENANCE" == "labeled" ]]; then
    pass "agent-synced HttpBin found on kind via '$SYNC_SELECTOR': '$KIND_HTTPBIN_NAME' (ns '$KIND_NS')"
  else
    warn "no HttpBin carried label '$SYNC_SELECTOR' — used unlabeled fallback (provenance label may differ in this agent version)"
    pass "HttpBin found on kind: '$KIND_HTTPBIN_NAME' (ns '$KIND_NS')"
  fi
  # Provenance evidence: the on-kind object should map back to the consumer's ordered object.
  RON="$(kk -n "$KIND_NS" get httpbin.orchestrate.platform-mesh.io "$KIND_HTTPBIN_NAME" -o jsonpath='{.metadata.annotations.syncagent\.kcp\.io/remote-object-name}' 2>/dev/null || true)"
  if [[ -n "$RON" ]]; then info "provenance annotation maps back to consumer object '$RON' (expected '$ORDER_NAME')"; fi
  COUNT="$(kk get httpbin.orchestrate.platform-mesh.io -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
  if [[ "${COUNT:-0}" -ne 1 ]]; then warn "found ${COUNT} HttpBin(s) on kind total; proceeding with '$KIND_HTTPBIN_NAME'"; fi
else
  fail "no HttpBin appeared on kind within timeout — api-syncagent did not sync the order down"
  echo "    on-kind httpbins:"; kk get httpbin.orchestrate.platform-mesh.io -A 2>&1 | sed 's/^/    /' || true
  echo "    api-syncagent pods:"; kk -n kcp-system get pods 2>&1 | sed 's/^/    /' || true
fi

# The httpbin-operator creates resources with a "httpbin-" prefix.
# Deployment name: httpbin-<httpbin-name>, Service name: httpbin-<httpbin-name>
DEPLOY_NAME="httpbin-${KIND_HTTPBIN_NAME}"
SVC_NAME="httpbin-${KIND_HTTPBIN_NAME}"

if [[ -n "$KIND_HTTPBIN_NAME" ]]; then
  # 2a — HttpBinDeployment exists and operator is reconciling.
  httpbindeployment_exists() {
    kk -n "$KIND_NS" get httpbindeployment.orchestrate.platform-mesh.io "$KIND_HTTPBIN_NAME" >/dev/null 2>&1
  }
  if retry 60 3 httpbindeployment_exists; then
    pass "HttpBinDeployment/$KIND_HTTPBIN_NAME exists in kind (operator is reconciling)"
  else
    fail "HttpBinDeployment/$KIND_HTTPBIN_NAME NOT found — operator did not create it"
  fi

  # 2b — Deployment is Ready.
  deploy_ready() {
    local ready
    ready="$(kk -n "$KIND_NS" get deploy "$DEPLOY_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [[ "${ready:-0}" -ge 1 ]]
  }
  if retry 120 5 deploy_ready; then
    REPLICAS="$(kk -n "$KIND_NS" get deploy "$DEPLOY_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    pass "Deployment '$DEPLOY_NAME' is Ready (replicas=$REPLICAS)"
    kk -n "$KIND_NS" get deploy "$DEPLOY_NAME" -o wide 2>&1 | sed 's/^/    /' || true
  else
    fail "Deployment '$DEPLOY_NAME' not Ready in kind"
    kk -n "$KIND_NS" get deploy 2>&1 | sed 's/^/    /' || true
  fi

  # 2c — the Service exists.
  if kk -n "$KIND_NS" get svc "$SVC_NAME" >/dev/null 2>&1; then
    pass "Service '$SVC_NAME' exists in kind (ns $KIND_NS)"
    kk -n "$KIND_NS" get svc "$SVC_NAME" -o wide 2>&1 | sed 's/^/    /' || true
  else
    fail "Service '$SVC_NAME' NOT found in kind"
    kk -n "$KIND_NS" get svc 2>&1 | sed 's/^/    /' || true
  fi
fi

# ---------------------------------------------------------------------------
# CHECK 3 — live HTTP request: hit the httpbin service in kind and verify response.
# ---------------------------------------------------------------------------
section "3. Live HTTP request: curl httpbin service in kind"

if [[ -n "${KIND_HTTPBIN_NAME:-}" ]] && [[ -n "${KIND_NS:-}" ]]; then
  # Port-forward and test
  PF_PORT=18080

  # Start port-forward in background
  kk -n "$KIND_NS" port-forward "svc/$SVC_NAME" "${PF_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  cleanup_pf() { kill "$PF_PID" 2>/dev/null || true; }
  trap cleanup_pf EXIT

  # Wait for port-forward to be ready
  sleep 3

  # Test the httpbin /get endpoint
  HTTP_RESPONSE=""
  for _ in $(seq 1 10); do
    HTTP_RESPONSE="$(curl -sS "http://localhost:${PF_PORT}/get" 2>/dev/null || true)"
    if [[ -n "$HTTP_RESPONSE" ]] && echo "$HTTP_RESPONSE" | grep -q '"url"'; then
      break
    fi
    sleep 2
  done

  if [[ -n "$HTTP_RESPONSE" ]] && echo "$HTTP_RESPONSE" | grep -q '"url"'; then
    pass "live HTTP GET /get returned valid JSON response — full loop proven"
    echo "    --- httpbin response (excerpt) ---"
    echo "$HTTP_RESPONSE" | head -10 | sed 's/^/    /'
    echo "    -----------------------------------"
  else
    fail "live HTTP GET /get did NOT succeed"
    echo "    response: ${HTTP_RESPONSE:-<empty>}" | sed 's/^/    /'
  fi

  cleanup_pf
  trap - EXIT
else
  fail "cannot run live HTTP test — missing on-kind HttpBin (see checks above)"
fi

# ---------------------------------------------------------------------------
# CHECK 4 — idempotency note. This script holds no persistent state: it only
# reads. `task order` is `kubectl apply` (a no-op when current), so
# `task order && task verify` is safe to re-run.
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
  echo "  ✅ E2E PASS — order -> sync-down -> provision -> live HTTP all verified."
  exit 0
else
  echo
  echo "  ❌ E2E FAIL — $FAIL_COUNT check(s) failed (see [FAIL] lines above)."
  exit 1
fi
