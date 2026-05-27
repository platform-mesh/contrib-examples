#!/usr/bin/env bash
# hack/provider-bind.sh — owner: kcp-expert (claims content + patch shapes from provider-portal, #9)
#
# Ensure the consumer (account) workspace $CONSUMER_WS on cluster A has its APIBinding to the
# provider's `postgresql.cnpg.io` APIExport ACCEPTING all three auto-added permissionClaims
# (namespaces, secrets, events). The api-syncagent needs these to create the target namespace and
# sync the connection Secret + events back; WITHOUT them the binding can still report phase=Bound
# while the Secret silently never syncs (CLAUDE.md trap #2). Run BEFORE `task order`.
#
# The platform-mesh operator's extraDefaultAPIBindings injects a CLAIM-LESS default binding to this
# export into every account-type workspace, and kcp rejects a second binding to the same export. So:
#   * if a binding referencing export postgresql.cnpg.io exists -> PATCH its spec.permissionClaims
#     (the live path for account workspaces);
#   * else -> apply config/kcp/apibinding.yaml (a manual/non-account consumer ws).
# kcp v0.31 serves APIBinding in both v1alpha1 (claim shape `all: true`) and v1alpha2
# (`selector.matchAll: true`); which the live object presents is unpredictable, so the patch is tried
# in the v1alpha1 shape first and falls back to v1alpha2, gating success on PermissionClaimsApplied.
#
# NON-INTERACTIVE: addresses the workspace via --server=.../clusters/$CONSUMER_WS rather than the
# `kubectl ws` plugin (which rejects --kubeconfig and would mutate the shared admin kubeconfig).
#
# Reads env exported by Taskfile.yml; do NOT hardcode paths/hosts/workspaces:
#   KCP_KUBECONFIG, CONSUMER_WS, KCP_EXTERNAL_HOST, KCP_PORT, TASKFILE_DIR
#
# Several helpers are invoked indirectly; shellcheck's "never invoked" check is not relevant here.
# shellcheck disable=SC2329
set -euo pipefail

: "${KCP_KUBECONFIG:?KCP_KUBECONFIG must be set}"
: "${CONSUMER_WS:?CONSUMER_WS must be set}"
: "${KCP_EXTERNAL_HOST:?KCP_EXTERNAL_HOST must be set}"
: "${KCP_PORT:?KCP_PORT must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

EXPORT_NAME="postgresql.cnpg.io"
CNPG_RESOURCE="clusters.postgresql.cnpg.io"
MANIFEST="${TASKFILE_DIR}/config/kcp/apibinding.yaml"
SERVER="https://${KCP_EXTERNAL_HOST}:${KCP_PORT}/clusters/${CONSUMER_WS}"

# permissionClaims payloads — v1alpha1 (all:true) and v1alpha2 (selector.matchAll:true). A merge
# patch replaces the whole array, which is correct: the operator's auto-binding starts with none.
CLAIMS_V1A1='{"spec":{"permissionClaims":[{"group":"","resource":"namespaces","all":true,"state":"Accepted"},{"group":"","resource":"secrets","all":true,"state":"Accepted"},{"group":"","resource":"events","all":true,"state":"Accepted"}]}}'
CLAIMS_V1A2='{"spec":{"permissionClaims":[{"group":"","resource":"namespaces","selector":{"matchAll":true},"state":"Accepted"},{"group":"","resource":"secrets","selector":{"matchAll":true},"state":"Accepted"},{"group":"","resource":"events","selector":{"matchAll":true},"state":"Accepted"}]}}'

say() { printf 'provider-bind: %s\n' "$*"; }
die() { printf 'provider-bind: ERROR — %s\n' "$*" >&2; exit 1; }

[ -s "${KCP_KUBECONFIG}" ] || die "cluster A admin kubeconfig not found at ${KCP_KUBECONFIG} — stand up cluster A first"
[ -f "${MANIFEST}" ] || die "missing ${MANIFEST}"
case "${CONSUMER_WS}" in
  *REPLACE-WITH-ACCOUNT*) die "CONSUMER_WS is still the placeholder — set it, e.g. task bind CONSUMER_WS=root:orgs:<org>:<account>" ;;
esac

# kubectl against $CONSUMER_WS on cluster A: admin auth+CA from the kubeconfig, endpoint overridden.
kc() { kubectl --kubeconfig "${KCP_KUBECONFIG}" --server "${SERVER}" "$@"; }

# Name of any APIBinding in $CONSUMER_WS that references our export (kcp owns the name; discover it).
find_binding() {
  kc get apibindings.apis.kcp.io \
    -o jsonpath="{range .items[?(@.spec.reference.export.name=='${EXPORT_NAME}')]}{.metadata.name}{'\n'}{end}" \
    2>/dev/null | head -n1 || true
}

# Authoritative "claims accepted AND applied" signal — a binding can be Bound with claims unapplied.
claims_applied() {
  [ "$(kc get apibinding "${BINDING_NAME}" -o jsonpath='{.status.conditions[?(@.type=="PermissionClaimsApplied")].status}' 2>/dev/null || true)" = "True" ]
}
wait_claims_applied() {
  local deadline=$((SECONDS + ${1:-30}))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    claims_applied && return 0
    sleep 2
  done
  return 1
}

# Connectivity preflight: a clear message beats a raw kubectl error if cluster A is down / WS wrong.
kc api-resources >/dev/null 2>&1 \
  || die "cannot reach cluster A at ${SERVER} (is cluster A up? is CONSUMER_WS '${CONSUMER_WS}' a real workspace?)"

say "consumer workspace: ${CONSUMER_WS}  (server ${SERVER})"
BINDING_NAME="$(find_binding)"

if [ -n "${BINDING_NAME}" ]; then
  say "found existing APIBinding '${BINDING_NAME}' (operator auto-binding) -> patching permissionClaims"
  if kc patch apibindings.apis.kcp.io "${BINDING_NAME}" --type=merge -p "${CLAIMS_V1A1}" >/dev/null 2>&1 && wait_claims_applied 30; then
    say "claims applied (v1alpha1 'all:true' shape)"
  elif kc patch apibindings.apis.kcp.io "${BINDING_NAME}" --type=merge -p "${CLAIMS_V1A2}" >/dev/null 2>&1 && wait_claims_applied 30; then
    say "claims applied (v1alpha2 'selector.matchAll' shape)"
  else
    kc get apibinding "${BINDING_NAME}" -o yaml 2>/dev/null | sed -n '/status:/,$p' >&2 || true
    die "could not get PermissionClaimsApplied=True on '${BINDING_NAME}' with either claim shape"
  fi
else
  say "no binding to ${EXPORT_NAME} in ${CONSUMER_WS} -> applying ${MANIFEST}"
  kc apply -f "${MANIFEST}"
  BINDING_NAME="$(find_binding)"
  [ -n "${BINDING_NAME}" ] || BINDING_NAME="${EXPORT_NAME}"
  wait_claims_applied 30 || say "WARNING: PermissionClaimsApplied not yet True on '${BINDING_NAME}' (continuing to Bound check)"
fi

say "waiting for APIBinding/${BINDING_NAME} phase=Bound"
phase=""
deadline=$((SECONDS + 120))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  phase="$(kc get apibinding "${BINDING_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${phase}" = "Bound" ] && break
  sleep 2
done
[ "${phase}" = "Bound" ] || die "APIBinding/${BINDING_NAME} did not reach Bound (last phase '${phase:-<none>}')"

# Final gate: BOTH Bound and claims applied (provider-portal: Bound alone is NOT enough — the Secret
# would silently not sync back).
claims_applied || die "APIBinding/${BINDING_NAME} is Bound but PermissionClaimsApplied!=True — the connection Secret would silently not sync back"
say "APIBinding/${BINDING_NAME}: Bound + PermissionClaimsApplied=True"

say "asserting ${CNPG_RESOURCE} is served in ${CONSUMER_WS}"
served=""
for _ in $(seq 1 30); do
  if kc api-resources --api-group=postgresql.cnpg.io 2>/dev/null | grep -qw clusters; then served=1; break; fi
  sleep 1
done
[ -n "${served}" ] || die "${CNPG_RESOURCE} not served in ${CONSUMER_WS}"

say "done: ${CONSUMER_WS} can now order ${CNPG_RESOURCE}"
