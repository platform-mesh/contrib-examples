#!/usr/bin/env bash
# hack/syncagent-publish.sh — owner: syncagent-expert
# Apply the on-kind RBAC + the PublishedResource for the CNPG Cluster API. Idempotent (apply).
#
# Reads env vars exported by Taskfile.yml; do NOT hardcode paths:
#   KIND_KUBECONFIG, TASKFILE_DIR
#
# Prereq (Taskfile `up` ordering): syncagent:install has already installed the PublishedResource
# CRD (chart crds.enabled=true) before this PublishedResource object is applied.
set -euo pipefail

: "${KIND_KUBECONFIG:?KIND_KUBECONFIG must be set}"
: "${TASKFILE_DIR:?TASKFILE_DIR must be set}"

RBAC="${TASKFILE_DIR}/config/syncagent/rbac.yaml"
PR="${TASKFILE_DIR}/config/syncagent/publishedresource-cluster.yaml"

echo "==> Applying api-syncagent RBAC + PublishedResource on kind"
kubectl --kubeconfig "${KIND_KUBECONFIG}" apply -f "${RBAC}" -f "${PR}"

# Best-effort readiness signal (NON-FATAL by design). The agent sets
# .status.resourceSchemaName on the PublishedResource only AFTER it has read the CRD and
# successfully created the APIResourceSchema in kcp — so a populated value also proves the agent
# reached kcp (the main connectivity risk). Waiting here gives provider:bind a ready APIExport and
# localizes agent/connectivity failures to this step. On timeout we only WARN — provider:bind has
# its own wait — so this can never make `task up` fail where it otherwise would not.
echo "==> Waiting (best-effort, up to 120s) for the agent to publish the APIResourceSchema..."
schema=""
deadline=$(( SECONDS + 120 ))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  schema="$(kubectl --kubeconfig "${KIND_KUBECONFIG}" get publishedresources.syncagent.kcp.io cnpg-clusters \
    -o jsonpath='{.status.resourceSchemaName}' 2>/dev/null || true)"
  if [ -n "${schema}" ]; then
    break
  fi
  sleep 2
done

if [ -n "${schema}" ]; then
  echo "==> Agent published APIResourceSchema: ${schema}"
  echo "    The CNPG Cluster API + permission claims are now in the APIExport 'api-syncagent'."
else
  echo "WARNING: PublishedResource cnpg-clusters still has no .status.resourceSchemaName after 120s." >&2
  echo "         The agent may not have reached kcp yet (provider:bind will still wait). If the bind" >&2
  echo "         later times out, inspect the agent logs:" >&2
  echo "         kubectl --kubeconfig \"\${KIND_KUBECONFIG}\" -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=100" >&2
fi
