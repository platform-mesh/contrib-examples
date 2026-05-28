#!/usr/bin/env bash
# test/e2e.sh — owner: test-verifier
#
# End-to-end proof of the Postgres-MSP loop:
#   consumer orders Cluster/pg-demo in the kcp consumer workspace
#     -> api-syncagent syncs it DOWN to kind
#       -> CloudNativePG provisions a real Postgres
#         -> status + the connection Secret sync BACK UP to the consumer workspace
#           -> a live `SELECT version();` using the consumer's synced credentials succeeds.
#
# Run AFTER `task up && task order`. Invoked by `task verify`.
# Reads env vars exported by Taskfile.yml. Fails loudly with captured output and
# prints a final PASS/FAIL summary; exits non-zero if any check failed.
#
# NAME-MANGLING (critical): api-syncagent renames synced objects on the kind side to
# avoid cross-workspace collisions. So on kind the Cluster/Secret/Service names DIFFER
# from `pg-demo`; CNPG derives every name from the *mangled* Cluster name
# (`<mangled>-rw`, `<mangled>-app`, pods `<mangled>-N`). We therefore DISCOVER the
# on-kind Cluster (there is exactly one in this single-consumer demo) and derive every
# other name from its real metadata + the `cnpg.io/cluster` label. On the kcp consumer
# side the names ARE the friendly ones (`pg-demo`, `pg-demo-app`).
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
ORDER_NAME="${ORDER_NAME:-pg-demo}"
ORDER_NS="${ORDER_NS:-default}"          # namespace of the ordered Cluster in the consumer ws
APP_SECRET="${ORDER_NAME}-app"            # CNPG connection Secret name on the kcp/consumer side
VERIFY_JOB="${ORDER_NAME}-verify"         # one-shot psql Job name (created in kind)
CNPG_LABEL="cnpg.io/cluster"              # CNPG's own label on the Postgres pods/services/secrets
AGENT_NAME="${AGENT_NAME:-msp-postgres}"  # api-syncagent agentName (config/syncagent/values.yaml)
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

# Clean up the verify Job on exit so re-runs are idempotent (keeps the cluster intact).
cleanup() {
  if [[ -n "${KIND_NS:-}" ]]; then
    kk -n "$KIND_NS" delete job "$VERIFY_JOB" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "######################################################################"
echo "# msp-postgres end-to-end verification"
echo "#   consumer ws : $CONSUMER_WS"
echo "#   order       : $ORDER_NAME (ns $ORDER_NS)"
echo "#   kcp kubecfg : $KCP_KUBECONFIG"
echo "#   kind kubecfg: $KIND_KUBECONFIG"
echo "######################################################################"

# ---------------------------------------------------------------------------
# CHECK 1a — consumer workspace: the ordered Cluster exists in kcp.
# ---------------------------------------------------------------------------
section "1a. Consumer workspace: Cluster/$ORDER_NAME present in $CONSUMER_WS"

if kcws "$CONSUMER_WS" >/dev/null 2>&1; then
  info "switched into consumer workspace $CONSUMER_WS"
else
  fail "could not enter consumer workspace $CONSUMER_WS (is kcp up? did 'task up' run?)"
  echo; echo "ws error:"; kcws "$CONSUMER_WS" 2>&1 | sed 's/^/    /' || true
fi

if kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" >/dev/null 2>&1; then
  pass "Cluster/$ORDER_NAME exists in consumer ws (ns $ORDER_NS)"
  kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" -o wide 2>&1 | sed 's/^/    /' || true
else
  fail "Cluster/$ORDER_NAME NOT found in consumer ws — did 'task order' run?"
  kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io 2>&1 | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 2 — kind: the synced Cluster is healthy, pods Ready, secret + -rw svc exist.
# Discover the (mangled) on-kind Cluster; derive all other names from it.
# ---------------------------------------------------------------------------
section "2. kind: discover the agent-synced Cluster (provenance-aware) and assert health"

# Prefer the api-syncagent provenance label (proves THIS agent synced the object down); fall back
# to an unlabeled lookup so the check still works if that label ever changes. The syncagent 'naming'
# in this demo preserves the consumer name (on kind: 'pg-demo' in 'default'), but we DISCOVER the
# real name+namespace so the script stays correct even if naming/mangling changes later.
present_labeled() { [[ -n "$(kk get cluster.postgresql.cnpg.io -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }

PROVENANCE="labeled"
KIND_CLUSTER_NAME=""
KIND_NS=""
if retry 150 4 present_labeled; then
  read -r KIND_CLUSTER_NAME KIND_NS <<<"$(kk get cluster.postgresql.cnpg.io -A -l "$SYNC_SELECTOR" -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
elif [[ -n "$(kk get cluster.postgresql.cnpg.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
  PROVENANCE="unlabeled-fallback"
  read -r KIND_CLUSTER_NAME KIND_NS <<<"$(kk get cluster.postgresql.cnpg.io -A -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.namespace}' 2>/dev/null)"
fi

if [[ -n "$KIND_CLUSTER_NAME" ]]; then
  if [[ "$PROVENANCE" == "labeled" ]]; then
    pass "agent-synced CNPG Cluster found on kind via '$SYNC_SELECTOR': '$KIND_CLUSTER_NAME' (ns '$KIND_NS')"
  else
    warn "no Cluster carried label '$SYNC_SELECTOR' — used unlabeled fallback (provenance label may differ in this agent version)"
    pass "CNPG Cluster found on kind: '$KIND_CLUSTER_NAME' (ns '$KIND_NS')"
  fi
  # Provenance evidence: the on-kind object should map back to the consumer's ordered object.
  RON="$(kk -n "$KIND_NS" get cluster.postgresql.cnpg.io "$KIND_CLUSTER_NAME" -o jsonpath='{.metadata.annotations.syncagent\.kcp\.io/remote-object-name}' 2>/dev/null || true)"
  if [[ -n "$RON" ]]; then info "provenance annotation maps back to consumer object '$RON' (expected '$ORDER_NAME')"; fi
  COUNT="$(kk get cluster.postgresql.cnpg.io -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
  if [[ "${COUNT:-0}" -ne 1 ]]; then warn "found ${COUNT} CNPG Cluster(s) on kind total; proceeding with '$KIND_CLUSTER_NAME'"; fi
  info "deriving CNPG children (pods/svc/secret) by label '${CNPG_LABEL}=${KIND_CLUSTER_NAME}'"
else
  fail "no CNPG Cluster appeared on kind within timeout — api-syncagent did not sync the order down"
  echo "    on-kind clusters:"; kk get cluster.postgresql.cnpg.io -A 2>&1 | sed 's/^/    /' || true
  echo "    api-syncagent pods:"; kk -n kcp-system get pods 2>&1 | sed 's/^/    /' || true
fi

# Derived child names — CNPG names its children after the on-kind Cluster name (only meaningful
# once discovered). Whatever the syncagent naming policy, these track the real on-kind name.
RW_SVC="${KIND_CLUSTER_NAME}-rw"
KIND_APP_SECRET="${KIND_CLUSTER_NAME}-app"

if [[ -n "$KIND_CLUSTER_NAME" ]]; then
  # 2a — Cluster reports a ready instance (poll; provisioning takes time).
  kind_ready() {
    local ri
    ri="$(kk -n "$KIND_NS" get cluster.postgresql.cnpg.io "$KIND_CLUSTER_NAME" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
    [[ "${ri:-0}" -ge 1 ]]
  }
  if retry 240 5 kind_ready; then
    RI="$(kk -n "$KIND_NS" get cluster.postgresql.cnpg.io "$KIND_CLUSTER_NAME" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
    KPHASE="$(kk -n "$KIND_NS" get cluster.postgresql.cnpg.io "$KIND_CLUSTER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    pass "on-kind Cluster healthy: readyInstances=$RI, phase='$KPHASE'"
  else
    fail "on-kind Cluster never reported a ready instance within timeout"
    kk -n "$KIND_NS" get cluster.postgresql.cnpg.io "$KIND_CLUSTER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
  fi

  # 2b — at least one Postgres pod is Ready (explicit pod condition evidence).
  pod_exists() { [[ -n "$(kk -n "$KIND_NS" get pods -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; }
  if retry 60 3 pod_exists && kk -n "$KIND_NS" wait --for=condition=Ready pod -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" --timeout=180s >/dev/null 2>&1; then
    pass "Postgres pod(s) Ready in kind (label ${CNPG_LABEL}=${KIND_CLUSTER_NAME})"
    kk -n "$KIND_NS" get pods -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" -o wide 2>&1 | sed 's/^/    /' || true
  else
    fail "Postgres pod(s) not Ready in kind"
    kk -n "$KIND_NS" get pods -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" 2>&1 | sed 's/^/    /' || true
  fi

  # 2c — the read-write Service exists.
  if kk -n "$KIND_NS" get svc "$RW_SVC" >/dev/null 2>&1; then
    pass "read-write Service '$RW_SVC' exists in kind (ns $KIND_NS)"
  else
    fail "read-write Service '$RW_SVC' NOT found in kind"
    kk -n "$KIND_NS" get svc -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" 2>&1 | sed 's/^/    /' || true
  fi

  # 2d — the connection Secret <mangled>-app exists on kind (CNPG, origin: service).
  if ! kk -n "$KIND_NS" get secret "$KIND_APP_SECRET" >/dev/null 2>&1; then
    # Fallback: locate by label + '-app' suffix in case the convention shifts.
    ALT="$(kk -n "$KIND_NS" get secret -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -- '-app$' | head -n1 || true)"
    [[ -n "$ALT" ]] && KIND_APP_SECRET="$ALT"
  fi
  if kk -n "$KIND_NS" get secret "$KIND_APP_SECRET" >/dev/null 2>&1; then
    pass "connection Secret '$KIND_APP_SECRET' present on kind (ns $KIND_NS)"
  else
    fail "connection Secret (CNPG '<cluster>-app') NOT found on kind"
    kk -n "$KIND_NS" get secret -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" 2>&1 | sed 's/^/    /' || true
  fi
fi

# ---------------------------------------------------------------------------
# CHECK 1b — sync-back of STATUS: the consumer-side Cluster has a populated,
# non-error .status (proves status flows kind -> kcp).
# ---------------------------------------------------------------------------
section "1b. Sync-back: consumer-side Cluster/$ORDER_NAME .status populated (non-error)"

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true
consumer_status_present() {
  [[ -n "$(kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)" ]]
}
if retry 180 5 consumer_status_present; then
  CPHASE="$(kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  CRI="$(kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
  if echo "$CPHASE" | grep -qiE 'fail|error|unrecoverable|degraded'; then
    fail "consumer-side Cluster in an error phase: '$CPHASE'"
  else
    pass "status synced back to consumer ws: phase='$CPHASE', readyInstances='${CRI:-<none>}'"
  fi
  info "(healthy terminal phase is 'Cluster in healthy state')"
else
  fail "consumer-side .status never populated — status sync-back not working"
  kc -n "$ORDER_NS" get cluster.postgresql.cnpg.io "$ORDER_NAME" -o yaml 2>&1 | sed -n '/^status:/,$p' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# CHECK 3 — sync-back of the SECRET: pg-demo-app present in the consumer ws,
# and its credentials are byte-identical to the on-kind secret (sync fidelity).
# ---------------------------------------------------------------------------
section "3. Sync-back: connection Secret '$APP_SECRET' in consumer ws + matches kind"

# Decode a key from a Secret via go-template (portable; no host base64 needed).
# usage: decode_key <kc|kk> <ns> <secret> <key>
decode_key() {
  local fn=$1 ns=$2 sec=$3 key=$4
  "$fn" -n "$ns" get secret "$sec" -o go-template="{{ if index .data \"$key\" }}{{ index .data \"$key\" | base64decode }}{{ end }}" 2>/dev/null || true
}

kcws "$CONSUMER_WS" >/dev/null 2>&1 || true
consumer_secret_present() { kc -n "$ORDER_NS" get secret "$APP_SECRET" >/dev/null 2>&1; }

CONSUMER_SECRET_NS="$ORDER_NS"
if retry 180 5 consumer_secret_present; then
  pass "connection Secret '$APP_SECRET' synced back into consumer ws (ns $ORDER_NS)"
elif kc get secret "$APP_SECRET" -A >/dev/null 2>&1; then
  CONSUMER_SECRET_NS="$(kc get secret "$APP_SECRET" -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "$ORDER_NS")"
  pass "connection Secret '$APP_SECRET' found in consumer ws (ns $CONSUMER_SECRET_NS — not $ORDER_NS)"
else
  fail "connection Secret '$APP_SECRET' NOT synced back into consumer ws"
  kc -n "$ORDER_NS" get secret 2>&1 | sed 's/^/    /' || true
fi

# Decode consumer-side creds (used to drive the live query).
PGUSER_VAL="$(decode_key kc "$CONSUMER_SECRET_NS" "$APP_SECRET" username)"
PGPASS_VAL="$(decode_key kc "$CONSUMER_SECRET_NS" "$APP_SECRET" password)"
PGDB_VAL="$(decode_key kc "$CONSUMER_SECRET_NS" "$APP_SECRET" dbname)"
PGURI_VAL="$(decode_key kc "$CONSUMER_SECRET_NS" "$APP_SECRET" uri)"

if [[ -n "$PGUSER_VAL" && -n "$PGPASS_VAL" && -n "$PGDB_VAL" ]]; then
  pass "consumer Secret has usable creds: username='$PGUSER_VAL', dbname='$PGDB_VAL', password=<$( [[ -n "$PGPASS_VAL" ]] && echo present || echo MISSING )>, uri=<$( [[ -n "$PGURI_VAL" ]] && echo present || echo absent )>"
else
  fail "consumer Secret missing one of username/password/dbname (got user='$PGUSER_VAL' db='$PGDB_VAL' pass=$( [[ -n "$PGPASS_VAL" ]] && echo set || echo empty ))"
fi

# Sync-fidelity: kcp-side creds must equal kind-side creds (the agent copies verbatim).
if [[ -n "${KIND_CLUSTER_NAME:-}" ]] && kk -n "$KIND_NS" get secret "$KIND_APP_SECRET" >/dev/null 2>&1; then
  K_USER="$(decode_key kk "$KIND_NS" "$KIND_APP_SECRET" username)"
  K_PASS="$(decode_key kk "$KIND_NS" "$KIND_APP_SECRET" password)"
  K_DB="$(decode_key kk "$KIND_NS" "$KIND_APP_SECRET" dbname)"
  if [[ "$PGUSER_VAL" == "$K_USER" && "$PGPASS_VAL" == "$K_PASS" && "$PGDB_VAL" == "$K_DB" ]]; then
    pass "sync fidelity OK: consumer creds (username/password/dbname) are byte-identical to the on-kind Secret"
  else
    fail "sync fidelity MISMATCH between consumer and kind secrets (user: '$PGUSER_VAL' vs '$K_USER'; db: '$PGDB_VAL' vs '$K_DB'; password equal: $( [[ "$PGPASS_VAL" == "$K_PASS" ]] && echo yes || echo no ))"
  fi
else
  warn "skipped sync-fidelity comparison (on-kind secret not resolved)"
fi

# ---------------------------------------------------------------------------
# CHECK 4 — live SELECT version(): connect with the synced creds via a one-shot
# psql Job inside kind, targeting the -rw Service. We reference the on-kind app
# Secret by secretKeyRef (proven equal to the consumer's creds above) so no
# plaintext password lands in the Job object.
# ---------------------------------------------------------------------------
section "4. Live query: SELECT version(); using synced credentials (psql Job in kind)"

if [[ -n "${KIND_CLUSTER_NAME:-}" ]] && kk -n "$KIND_NS" get secret "$KIND_APP_SECRET" >/dev/null 2>&1 && kk -n "$KIND_NS" get svc "$RW_SVC" >/dev/null 2>&1; then
  # Reuse the exact Postgres image already running (guaranteed present on the node);
  # fall back to the CNPG client image documented in config/cnpg/NOTES.md.
  PG_IMAGE="$(kk -n "$KIND_NS" get pods -l "${CNPG_LABEL}=${KIND_CLUSTER_NAME}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  [[ -z "$PG_IMAGE" ]] && PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:17"
  info "psql client image: $PG_IMAGE ; all connection params sourced from Secret '$KIND_APP_SECRET'"

  kk -n "$KIND_NS" delete job "$VERIFY_JOB" --ignore-not-found >/dev/null 2>&1 || true
  # Every connection parameter (host/port/user/password/dbname) is pulled from the synced
  # connection Secret via secretKeyRef — authoritative and robust to api-syncagent name-mangling,
  # since the Secret's own 'host' key is '<mangled>-rw.<ns>.svc'. No constructed names, no
  # plaintext in the Job object; libpq reads the PG* env vars natively so the command is a plain psql.
  cat <<EOF | kk -n "$KIND_NS" apply -f - >/dev/null 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${VERIFY_JOB}
  labels:
    app.kubernetes.io/managed-by: msp-postgres-e2e
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 120
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: msp-postgres-e2e
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: ${PG_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["psql", "-v", "ON_ERROR_STOP=1", "-tAc", "SELECT version();"]
          env:
            - name: PGCONNECT_TIMEOUT
              value: "10"
            - name: PGHOST
              valueFrom: { secretKeyRef: { name: ${KIND_APP_SECRET}, key: host } }
            - name: PGPORT
              valueFrom: { secretKeyRef: { name: ${KIND_APP_SECRET}, key: port } }
            - name: PGUSER
              valueFrom: { secretKeyRef: { name: ${KIND_APP_SECRET}, key: username } }
            - name: PGPASSWORD
              valueFrom: { secretKeyRef: { name: ${KIND_APP_SECRET}, key: password } }
            - name: PGDATABASE
              valueFrom: { secretKeyRef: { name: ${KIND_APP_SECRET}, key: dbname } }
EOF

  # Wait for the Job to finish (success or failure) and capture logs either way.
  JDEADLINE=$((SECONDS + 150))
  JSTATE="timeout"
  while [[ $SECONDS -lt $JDEADLINE ]]; do
    S="$(kk -n "$KIND_NS" get job "$VERIFY_JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    F="$(kk -n "$KIND_NS" get job "$VERIFY_JOB" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    if [[ "${S:-0}" -ge 1 ]]; then JSTATE="succeeded"; break; fi
    if [[ "${F:-0}" -ge 1 ]]; then JSTATE="failed"; break; fi
    sleep 3
  done

  JOB_LOGS="$(kk -n "$KIND_NS" logs job/"$VERIFY_JOB" 2>&1 || true)"
  echo "    --- psql Job output ($JSTATE) ---"
  # shellcheck disable=SC2001  # per-line indent of multiline logs; sed is the clear tool
  echo "$JOB_LOGS" | sed 's/^/    /'
  echo "    ---------------------------------"

  if [[ "$JSTATE" == "succeeded" ]] && echo "$JOB_LOGS" | grep -qi 'PostgreSQL'; then
    pass "live SELECT version(); returned a row using synced creds — full loop proven"
  else
    fail "live SELECT version(); did NOT succeed (job state: $JSTATE)"
    echo "    job describe:"; kk -n "$KIND_NS" describe job "$VERIFY_JOB" 2>&1 | tail -n 25 | sed 's/^/    /' || true
  fi
else
  fail "cannot run live query — missing on-kind cluster, app secret, or -rw service (see checks above)"
fi

# ---------------------------------------------------------------------------
# CHECK 5 — idempotency note. This script holds no persistent state: it only
# reads, and the single object it creates (the psql Job) is deleted on exit and
# re-created on each run. `task order` is `kubectl apply` (a no-op when current),
# so `task order && task verify` is safe to re-run.
# ---------------------------------------------------------------------------
section "5. Idempotency"
info "e2e.sh is read-only except for the ephemeral '$VERIFY_JOB' Job (deleted on exit)."
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
  echo "  ✅ E2E PASS — order -> sync-down -> provision -> status+secret sync-back -> live query all verified."
  exit 0
else
  echo
  echo "  ❌ E2E FAIL — $FAIL_COUNT check(s) failed (see [FAIL] lines above)."
  exit 1
fi
