# msp-postgres-localsetup — Postgres 15 MSP with the backing DB in a SECOND kind cluster

A variant of [`../msp-postgres`](../msp-postgres) adapted for **Platform Mesh local-setup**. The
control plane (kcp + portal) is the existing local-setup cluster; the **data plane** — CloudNativePG
and the kcp **api-syncagent** — runs in a **separate** kind cluster that connects *outbound* to the
local-setup kcp. Consumers order CloudNativePG's *native* `Cluster` API (passthrough, no custom
operator); "order Postgres 15" creates a `Cluster` pinned to `ghcr.io/cloudnative-pg/postgresql:15`.

See [`docs/architecture.md`](docs/architecture.md) for the Mermaid flow.

> **Status:** this directory (Workstream B) provides the backing-cluster bring-up. The control-plane
> side (the `postgresql.cnpg.io` APIExport, portal registration, account `APIBinding`, and the
> kcp `root.kcp.localhost` reachability change) lives on the `feat/msp-postgres-localsetup` branch
> of the **helm-charts** repo (Workstream A). The end-to-end live runbook is finalised by the
> integrator.

**Matched stack:** kcp `v0.31.0` (provided by local-setup) · api-syncagent `v0.6.0` · CloudNativePG
`v1.29.1` · PostgreSQL `15`.

---

## Two clusters, one control plane

```text
macOS host / Docker Desktop
┌──────────────────────────────────────┐      ┌──────────────────────────────────────┐
│ kind cluster A — local-setup          │      │ kind cluster B — msp-postgres-backing │
│  • kcp (front-proxy → host :8443)     │      │  • CloudNativePG v1.29.1              │
│  • portal + Keycloak                  │◄─────│  • api-syncagent v0.6.0 ── dials out ─┤
│  • ws root:providers:postgres-provider│ :8443│  • Postgres 15 pods + PVCs + Secret   │
│    APIExport postgresql.cnpg.io       │      │                                       │
│  • account ws: APIBinding + ordered   │      │  reaches A via root.kcp.localhost     │
│    Cluster + synced status/Secret     │      │                                       │
└──────────────────────────────────────┘      └──────────────────────────────────────┘
```

Both kind clusters sit on the default `kind` Docker network. The agent in B reaches A's kcp over
**two hops**, both via `root.kcp.localhost:8443`: the bootstrap kubeconfig server, and the
`APIExportEndpointSlice` virtual-workspace URL that A's kcp advertises. The hostname **must** be
`root.kcp.localhost` — cluster A fronts kcp with an Istio gateway that routes by SNI, and only that
name has a TLSRoute. Since `root.kcp.localhost` would otherwise resolve to `127.0.0.1` inside a pod,
the agent's `hostAliases` (in `config/syncagent/values.yaml`) maps it to the shared `kind` network's
host-gateway, which forwards to the host's published `:8443`.

---

## Integration contract (must match Workstream A)

- **APIExport name `postgresql.cnpg.io`** — set in `config/syncagent/values.yaml`.
  `apiExportEndpointSliceName` is the functional knob (renders `--apiexportendpointslice-ref`);
  `apiExportName` documents intent but is inert in the v0.6.0 chart. It MUST equal the APIExport
  provider-portal creates in cluster A's provider workspace, so kcp's auto-created default
  `APIExportEndpointSlice` carries the same name (that is what the agent follows). (Names are
  arbitrary in kcp; passthrough works identically — the standalone `msp-postgres` uses `api-syncagent`.)
- **Account `APIBinding` must `Accept` all three auto-added permissionClaims** — `namespaces`,
  `secrets`, `events` — or the connection Secret never syncs back (silent-failure trap). That
  binding is owned by Workstream A (auto-added to every account via `extraDefaultAPIBindings`).

---

## Prerequisites

| Tool | Notes |
|------|-------|
| Cluster A up | The Platform Mesh local-setup on the `feat/msp-postgres-localsetup` branch, with the postgres-provider example-data applied and kcp reachable as `root.kcp.localhost:8443` |
| `docker` | Docker Desktop (macOS) — the shared `kind` network's host-gateway forwards to the host's published `:8443` (used by the agent's `hostAliases`) |
| `kind` | Any recent release |
| `kubectl` + `kubectl-ws` | The kcp plugin (`kubectl ws`); local-setup installs it |
| `helm` | v3 |
| `task` | [Taskfile](https://taskfile.dev) runner — `brew install go-task` |
| `psql` | Optional; only for the live `SELECT version()` in `task verify` (the e2e Job runs it in-cluster regardless) |

---

## Quickstart

Stand up cluster A first (helm-charts, Workstream A). Then, **from this directory:**

```sh
task kind:up            # create the backing kind cluster (cluster B)
task cnpg:install       # install CloudNativePG into B
task syncagent:kubeconfig   # derive a kubeconfig to A's provider ws, store as a Secret in B
task syncagent:install  # helm-install api-syncagent into B
task syncagent:publish  # apply PublishedResource + RBAC; agent fills A's APIExport
```

`task kind:up cnpg:install syncagent:kubeconfig syncagent:install syncagent:publish` runs them in
one shot (each step is idempotent).

Then bind + order + verify against an **account workspace in cluster A** (set `CONSUMER_WS` to the
real account path — the default is a placeholder that fails loudly):

```sh
task bind   CONSUMER_WS=root:orgs:<org>:<account>   # accept all 3 permissionClaims (see below)
task order  CONSUMER_WS=root:orgs:<org>:<account>
task verify CONSUMER_WS=root:orgs:<org>:<account>
task down   # delete the backing cluster (cluster A is left untouched)
```

`task bind` is required because the operator's `extraDefaultAPIBindings` creates a **claim-less**
auto-binding; it patches that binding (or applies `config/kcp/apibinding.yaml`) to Accept all three
claims, otherwise the connection Secret silently never syncs back.

Run `task` (no args) to list targets.

> **`kubectl ws` side effect.** `order`/`verify` run `kubectl ws <CONSUMER_WS>` against
> `$KCP_KUBECONFIG` (cluster A's admin kubeconfig), which rewrites that kubeconfig's current-context
> server to the target workspace. This is standard kcp navigation and is reversible with
> `kubectl ws :root`.

---

## Per-target reference

| Target | Script / Entrypoint | Owner | Idempotent? | Notes |
|--------|---------------------|-------|-------------|-------|
| `tools:check` | `hack/tools-check.sh` | k8s-expert | ✅ | Fails fast if a required CLI (incl. `kubectl-ws`) is missing |
| `kind:up` | `hack/kind-up.sh` | k8s-expert | ✅ | Creates `msp-postgres-backing`; exports `.kube/kind.kubeconfig` |
| `kind:down` | `hack/kind-down.sh` | k8s-expert | ✅ | No-op if cluster absent |
| `cnpg:install` | `hack/cnpg-install.sh` | postgres-expert | ✅ | `apply --server-side`; waits for rollout |
| `syncagent:kubeconfig` | `hack/syncagent-kubeconfig.sh` | syncagent-expert | ✅ | **Needs cluster A up.** Derives provider-ws kubeconfig → Secret in B |
| `syncagent:install` | `hack/syncagent-install.sh` | syncagent-expert | ✅ | Helm install/upgrade |
| `syncagent:publish` | `hack/syncagent-publish.sh` | syncagent-expert | ✅ | `PublishedResource` + RBAC; triggers schema generation in A |
| `bind` | `hack/provider-bind.sh` | kcp-expert | ✅ | **Run before order.** Patches the account's claim-less auto-binding (or applies `config/kcp/apibinding.yaml`) to Accept namespaces/secrets/events; gates on Bound **and** `PermissionClaimsApplied=True`. Non-interactive (`--server=.../clusters/$CONSUMER_WS`) |
| `order` | `hack/order.sh` | postgres-expert | ✅ | `apply` Cluster/pg-demo into `CONSUMER_WS` |
| `verify` | `test/e2e.sh` | test-verifier | read-only | Full loop; expects PostgreSQL 15 |
| `status` | inline | developer | read-only | Safe any time |
| `down` | → `kind:down` | developer | ✅ | Backing cluster only |

There are **no `kcp:*` targets** — kcp is cluster A's, not a host process.

---

## Env vars contract

`Taskfile.yml` exports these to every `hack/` script — scripts **must not** hardcode the values.

| Var | Value | Purpose |
|-----|-------|---------|
| `KUBECONFIG` / `KCP_KUBECONFIG` | `<helm-charts>/.secret/kcp/admin.kubeconfig` | Cluster A's kcp admin kubeconfig (absolute) |
| `KIND_KUBECONFIG` | `.kube/kind.kubeconfig` | **Use explicitly** for all `kubectl` ops against the backing cluster |
| `SYNCAGENT_VERSION` | `0.6.0` | api-syncagent version |
| `CNPG_VERSION` | `1.29.1` | CloudNativePG version |
| `KIND_CLUSTER` | `msp-postgres-backing` | Backing kind cluster name |
| `KIND_CONTEXT` | `kind-msp-postgres-backing` | kubectl context for the backing cluster |
| `AGENT_NAME` | `msp-postgres-backing` | api-syncagent name + `syncagent.kcp.io/agent-name` label (e2e keys on it) |
| `PROVIDER_WS` | `root:providers:postgres-provider` | Provider workspace in cluster A (holds the APIExport) |
| `CONSUMER_WS` | `root:orgs:REPLACE-WITH-ACCOUNT` | **Placeholder** — set to the real account workspace in cluster A |
| `ORDER_NAME` | `pg-demo` | Ordered `Cluster` name |
| `ORDER_NS` | `default` | Ordered `Cluster` namespace |
| `KCP_EXTERNAL_HOST` | `root.kcp.localhost` | Cluster A's kcp hostname (the only SNI its Istio gateway routes); resolved in-pod via `hostAliases` |
| `KCP_PORT` | `8443` | Cluster A's front-proxy port |
| `TASKFILE_DIR` | _(this directory)_ | Absolute path for building relative paths in scripts |

---

## Troubleshooting (starting points; integrator finalises)

- **`syncagent:kubeconfig` errors that cluster A's kubeconfig is missing** — stand up cluster A on
  the branch first; `KCP_KUBECONFIG` must point at a real `admin.kubeconfig`.
- **Agent can't reach kcp / `root.kcp.localhost` unresolvable or connection refused** — the
  `hostAliases` block in `config/syncagent/values.yaml` is enabled with a placeholder IP
  (`172.18.0.1`); verify/override it with the real `kind` network host-gateway:
  `docker network inspect kind -f '{{ (index .IPAM.Config 0).Gateway }}'`.
- **TLS/routing errors despite reachability** — confirm the agent connects as `root.kcp.localhost`
  (SNI); any other name fails A's Istio SNI routing.
- **Secret never syncs back even though the binding is `Bound`** — this is the silent trap: the
  operator's auto-binding is claim-less. Run `task bind CONSUMER_WS=...` (gates on
  `PermissionClaimsApplied=True`, not just Bound). If the live binding presents the v1alpha2 claim
  shape (`selector.matchAll`) the script falls back to it automatically; inspect with
  `kubectl --kubeconfig "$KCP_KUBECONFIG" --server="https://root.kcp.localhost:8443/clusters/$CONSUMER_WS" get apibinding <name> -o yaml`.
- **Inspect the agent:**
  `kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=80`
