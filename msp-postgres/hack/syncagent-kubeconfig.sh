#!/usr/bin/env bash
# hack/syncagent-kubeconfig.sh — owner: syncagent-expert
#
# Build the kubeconfig the api-syncagent (running INSIDE kind) uses to reach kcp, and store it as a
# Secret on the kind cluster. Idempotent.
#
# What it does:
#   1. Copies the kcp admin kubeconfig and navigates the COPY to the provider workspace
#      ($PROVIDER_WS) with `kubectl ws` (does not disturb the shared admin kubeconfig).
#   2. Minifies+flattens it to a single self-contained cluster/context/user.
#   3. Rewrites the server host to https://$KCP_EXTERNAL_HOST:<port> (port taken from the snapshot,
#      path preserved) and sets insecure-skip-tls-verify: true (dropping the CA bundle) — this makes
#      kcp reachable, and TLS acceptable, from inside the kind network.
#   4. Stores it on kind as Secret `kcp-kubeconfig` (key `kubeconfig`) in namespace kcp-system.
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths/hosts/workspaces:
#   KCP_KUBECONFIG, KIND_KUBECONFIG, PROVIDER_WS, KCP_EXTERNAL_HOST
#
# !! CONNECTIVITY DEPENDENCY (coordinate with kcp-expert) !!
# This script only fixes hop #1 (the bootstrap kubeconfig the agent reads). The agent then follows
# the APIExportEndpointSlice `api-syncagent` virtual-workspace URL; THAT host is whatever kcp
# advertises via its external hostname. For the in-kind agent to reach it, kcp MUST advertise
# $KCP_EXTERNAL_HOST (host.docker.internal) for its front-proxy / virtual-workspace URLs.
# Also: the admin kubeconfig at $KCP_KUBECONFIG must be reachable from THIS host (where `kubectl ws`
# runs) — typically a localhost:PORT server. The rewrite below swaps that host for the kind-reachable
# one only in the agent's copy.
set -euo pipefail

: "${KCP_KUBECONFIG:?KCP_KUBECONFIG must be set}"
: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${PROVIDER_WS:?PROVIDER_WS must be set}"
: "${KCP_EXTERNAL_HOST:?KCP_EXTERNAL_HOST must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

# `kubectl ws` is the kcp kubectl plugin vendored into bin/ by hack/tools-kcp.sh; make sure it (and
# kubectl-kcp) are found whether or not they are installed globally.
export PATH="${TASKFILE_DIR}/bin:${PATH}"

SNAP="$(mktemp -t kcp-syncagent-snap.XXXXXX)"
AGENT_KC="$(mktemp -t kcp-syncagent-kubeconfig.XXXXXX)"
cleanup() { rm -f "${SNAP}" "${AGENT_KC}" "${AGENT_KC}.tmp"; }
trap cleanup EXIT

echo "==> Snapshotting kcp kubeconfig and entering provider workspace: ${PROVIDER_WS}"
cp "${KCP_KUBECONFIG}" "${SNAP}"
KUBECONFIG="${SNAP}" kubectl ws "${PROVIDER_WS}"

# Reduce to just the current (provider-ws) context, with certs/tokens embedded inline.
KUBECONFIG="${SNAP}" kubectl config view --raw --minify --flatten > "${AGENT_KC}"

# After --minify there is exactly one cluster; read its name + server.
CLUSTER="$(KUBECONFIG="${AGENT_KC}" kubectl config view -o jsonpath='{.clusters[0].name}')"
OLD_SERVER="$(KUBECONFIG="${AGENT_KC}" kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -z "${OLD_SERVER}" ]]; then
  echo "ERROR: could not read server URL from the provider-workspace kubeconfig" >&2
  exit 1
fi

# Parse https://HOST:PORT/PATH... → keep PORT (per task) and PATH, swap HOST for $KCP_EXTERNAL_HOST.
rest="${OLD_SERVER#*://}"        # HOST:PORT/PATH...
hostport="${rest%%/*}"          # HOST:PORT
path="${rest#"${hostport}"}"    # /PATH... (possibly empty)
if [[ "${hostport}" == *:* ]]; then
  port="${hostport##*:}"
else
  port="443"
fi
NEW_SERVER="https://${KCP_EXTERNAL_HOST}:${port}${path}"

echo "==> Rewriting agent kubeconfig server: ${OLD_SERVER} -> ${NEW_SERVER} (insecure-skip-tls-verify)"
# Drop the CA bundle first (it conflicts with insecure-skip-tls-verify and is host-specific anyway),
# then set the kind-reachable server + insecure flag. The grep filter is name-agnostic and portable
# across BSD/GNU sed.
grep -v 'certificate-authority-data:' "${AGENT_KC}" > "${AGENT_KC}.tmp" && mv "${AGENT_KC}.tmp" "${AGENT_KC}"
KUBECONFIG="${AGENT_KC}" kubectl config set-cluster "${CLUSTER}" \
  --server="${NEW_SERVER}" --insecure-skip-tls-verify=true >/dev/null

echo "==> Ensuring namespace kcp-system on kind"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create namespace kcp-system \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Storing Secret kcp-kubeconfig (key 'kubeconfig') in kcp-system"
kubectl --kubeconfig "${KIND_KUBECONFIG}" create secret generic kcp-kubeconfig \
  --namespace kcp-system \
  --from-file "kubeconfig=${AGENT_KC}" \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f -

echo "==> Done. The agent will read the provider-workspace kubeconfig from this Secret."
