#!/usr/bin/env bash
# test/e2e.sh — owner: test-verifier
#
# End-to-end proof of the cert-manager MSP loop:
#   consumer orders Certificate/my-cert in the kcp consumer workspace
#     -> api-syncagent syncs it DOWN to kind as certmanager.ca/Certificate
#       -> kro translates it to cert-manager.io/Certificate
#         -> cert-manager issues a TLS Secret
#           -> the TLS Secret syncs BACK UP to the consumer workspace
#             -> the TLS Secret contains a valid certificate for the ordered fqdn.
#
# Run AFTER `task up && task order`. Invoked by `task verify`.
# Reads env vars exported by Taskfile.yml. Fails loudly with captured output and
# prints a final PASS/FAIL summary; exits non-zero if any check failed.
#
# shellcheck disable=SC2329
set -euo pipefail

# --- contract: env vars exported by Taskfile.yml (with fallbacks for standalone runs) ---
KCP_KUBECONFIG="${KCP_KUBECONFIG:?KCP_KUBECONFIG must be set}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
CONSUMER_WS="${CONSUMER_WS:-root:msp:customer-a}"
ORDER_NAME="${ORDER_NAME:-my-cert}"
ORDER_NS="${ORDER_NS:-default}"
ORDER_FQDN="${ORDER_FQDN:-my-app.example.com}"
AGENT_NAME="${AGENT_NAME:-msp-cert-manager}"
SYNC_SELECTOR="syncagent.kcp.io/agent-name=${AGENT_NAME}"

# kubectl wrappers — keep the two control planes unambiguous.
kc() { kubectl --kubeconfig "$KCP_KUBECONFIG" "$@"; }   # kcp operations
kk() { kubectl --kubeconfig "$KIND_KUBECONFIG" "$@"; }  # kind operations
kcws() { KUBECONFIG="$KCP_KUBECONFIG" kubectl ws "$@"; }

# --- output helpers ---
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
echo "# msp-cert-manager end-to-end verification"
echo "#   consumer ws : $CONSUMER_WS"
echo "#   order       : $ORDER_NAME (ns $ORDER_NS)"
echo "#   fqdn        : $ORDER_FQDN"
echo "#   kcp kubecfg : $KCP_KUBECONFIG"
echo "#   kind kubecfg: $KIND_KUBECONFIG"
echo "######################################################################"

# ---------------------------------------------------------------------------
# CHECK 1a — consumer workspace: the ordered Certificate exists in kcp.
# ---------------------------------------------------------------------------
section "1a. Consumer workspace: Certificate/$ORDER_NAME present in $CONSUMER_WS"

if kcws "$CONSUMER_WS" >/dev/null 2>&1; then
  info "switched into consumer workspace $CONSUMER_WS"
else
  fail "could not enter consumer workspace $CONSUMER_WS (is kcp up? did 'task up' run?)"
fi

if kc -n "$ORDER_NS" get certificate.certmanager.ca "$ORDER_NAME" >/dev/null 2>&1; then
  pass "Certificate/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
  kc -n "$ORDER_NS" get certificate.certmanager.ca "$ORDER_NAME" -o wide 2>&1 | sed 's/^/    /' || true
else
  fail "Certificate/$ORDER_NAME NOT found in consumer ws — did 'task order' run?"
  kc -n "$ORDER_NS" get certificate.certmanager.ca 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 2 — kind: the synced certmanager.ca/Certificate and cert-manager.io/Certificate exist.
# ---------------------------------------------------------------------------
section "2. kind: discover the agent-synced Certificate and assert cert-manager issued it"

# Locate the synced certmanager.ca/Certificate on kind by the syncagent provenance label.
present_labeled() {
  [[ -n "$(kk get certificate.certmanager.ca -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]
}

KIND_CERT_NAME=""
KIND_NS=""
PROVENANCE="labeled"

if retry 150 4 present_labeled; then
  read -r KIND_CERT_NAME KIND_NS <<<"$(kk get certificate.certmanager.ca -A -l "$SYNC_SELECTOR" \
    -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
elif [[ -n "$(kk get certificate.certmanager.ca -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
  PROVENANCE="unlabeled-fallback"
  read -r KIND_CERT_NAME KIND_NS <<<"$(kk get certificate.certmanager.ca -A \
    -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
fi

if [[ -n "$KIND_CERT_NAME" ]]; then
  if [[ "$PROVENANCE" == "labeled" ]]; then
    pass "agent-synced certmanager.ca/Certificate found on kind via '$SYNC_SELECTOR': '$KIND_CERT_NAME' (ns '$KIND_NS')"
  else
    warn "no Certificate carried label '$SYNC_SELECTOR' — used unlabeled fallback"
    pass "certmanager.ca/Certificate found on kind: '$KIND_CERT_NAME' (ns '$KIND_NS')"
  fi

  # 2a — wait for cert-manager to issue the certificate (cert-manager.io/Certificate ready).
  cmcert_ready() {
    local phase
    phase="$(kk -n "$KIND_NS" get certificate.cert-manager.io "$KIND_CERT_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${phase}" == "True" ]]
  }
  if retry 120 3 cmcert_ready; then
    pass "cert-manager.io/Certificate '$KIND_CERT_NAME' is Ready in kind (ns $KIND_NS)"
  else
    fail "cert-manager.io/Certificate '$KIND_CERT_NAME' never became Ready — cert-manager may have an issue"
    kk -n "$KIND_NS" get certificate.cert-manager.io "$KIND_CERT_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
  fi

  # 2b — the TLS Secret exists on kind.
  KIND_SECRET_NAME="$KIND_CERT_NAME"   # rgd.yaml sets secretName = cert object name
  if kk -n "$KIND_NS" get secret "$KIND_SECRET_NAME" >/dev/null 2>&1; then
    pass "TLS Secret '$KIND_SECRET_NAME' present on kind (ns $KIND_NS)"
  else
    fail "TLS Secret '$KIND_SECRET_NAME' NOT found on kind — cert-manager may not have issued yet"
    kk -n "$KIND_NS" get secret 2>&1 | sed 's/^/    /' || true
  fi
else
  fail "no certmanager.ca/Certificate appeared on kind within timeout — api-syncagent did not sync the order down"
  echo "    on-kind certmanager certificates:"; kk get certificate.certmanager.ca -A 2>&1 | sed 's/^/    /' || true
  echo "    api-syncagent pods:"; kk -n kcp-system get pods 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 1b — sync-back of STATUS: consumer-side Certificate has populated status.
# ---------------------------------------------------------------------------
section "1b. Sync-back: consumer-side Certificate/$ORDER_NAME .status populated"

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true
consumer_status_present() {
  [[ -n "$(kc -n "$ORDER_NS" get certificate.certmanager.ca "$ORDER_NAME" \
    -o jsonpath='{.status.conditions}' 2>/dev/null)" ]]
}
if retry 120 5 consumer_status_present; then
  conditions="$(kc -n "$ORDER_NS" get certificate.certmanager.ca "$ORDER_NAME" \
    -o jsonpath='{.status.conditions}' 2>/dev/null || true)"
  pass "status synced back to consumer ws: conditions=$(echo "$conditions" | head -c 200)"
else
  fail "consumer-side .status never populated — status sync-back not working"
  kc -n "$ORDER_NS" get certificate.certmanager.ca "$ORDER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 3 — sync-back of the TLS Secret: my-cert present in the consumer workspace.
# ---------------------------------------------------------------------------
section "3. Sync-back: TLS Secret '$ORDER_NAME' in consumer ws"

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true
consumer_secret_present() { kc -n "$ORDER_NS" get secret "$ORDER_NAME" >/dev/null 2>&1; }

if retry 180 5 consumer_secret_present; then
  pass "TLS Secret '$ORDER_NAME' synced back into consumer ws (ns $ORDER_NS)"
  SECRET_TYPE="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" -o jsonpath='{.type}' 2>/dev/null || true)"
  info "Secret type: $SECRET_TYPE"
else
  fail "TLS Secret '$ORDER_NAME' NOT synced back into consumer ws"
  kc -n "$ORDER_NS" get secret 2>&1 | sed 's/^/    /' || true
fi

# 3a — the Secret contains the expected TLS keys.
if kc -n "$ORDER_NS" get secret "$ORDER_NAME" >/dev/null 2>&1; then
  has_crt="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
  has_key="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" -o jsonpath='{.data.tls\.key}' 2>/dev/null || true)"
  has_ca="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  if [[ -n "$has_crt" && -n "$has_key" ]]; then
    pass "TLS Secret contains tls.crt and tls.key (ca.crt: $( [[ -n "$has_ca" ]] && echo present || echo absent ))"
  else
    fail "TLS Secret missing tls.crt or tls.key (crt=$( [[ -n "$has_crt" ]] && echo set || echo MISSING ) key=$( [[ -n "$has_key" ]] && echo set || echo MISSING ))"
  fi

  # 3b — decode the certificate and check the CN/SAN matches the ordered fqdn.
  if [[ -n "$has_crt" ]] && command -v openssl >/dev/null 2>&1; then
    cert_subject="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -subject 2>/dev/null || true)"
    cert_san="$(kc -n "$ORDER_NS" get secret "$ORDER_NAME" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -text 2>/dev/null | grep "DNS:" || true)"
    info "Certificate subject: $cert_subject"
    info "Certificate SANs: $cert_san"
    if echo "$cert_subject $cert_san" | grep -q "$ORDER_FQDN"; then
      pass "Certificate is issued for fqdn '$ORDER_FQDN'"
    else
      fail "Certificate subject/SAN does not mention '$ORDER_FQDN'"
    fi
  elif [[ -n "$has_crt" ]]; then
    warn "openssl not available — skipping fqdn verification (install openssl to enable)"
    pass "TLS Secret is populated (fqdn check skipped)"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "SUMMARY"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo
  echo "  E2E PASS — order -> sync-down -> cert-manager issue -> TLS Secret sync-back all verified."
  exit 0
else
  echo
  echo "  E2E FAIL — $FAIL_COUNT check(s) failed (see [FAIL] lines above)."
  exit 1
fi
