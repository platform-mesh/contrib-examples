# msp-postgres-localsetup — Postgres 15 MSP with the backing DB in a SECOND kind cluster

A variant of [`../msp-postgres`](../msp-postgres) adapted for **Platform Mesh local-setup**. The
control plane (kcp + portal) is the existing local-setup cluster; the **data plane** — CloudNativePG
and the kcp **api-syncagent** — runs in a **separate** kind cluster that connects *outbound* to the
local-setup kcp. Consumers order CloudNativePG's *native* `Cluster` API (passthrough, no custom
operator); "order Postgres 15" creates a `Cluster` pinned to `ghcr.io/cloudnative-pg/postgresql:15`.

See [`docs/architecture.md`](docs/architecture.md) for the Mermaid flow.

> **Status: VERIFIED END-TO-END (2026-05-27, Docker Desktop / macOS arm64).** The full loop was
> proven live: order Postgres 15 in a cluster-A consumer workspace → api-syncagent (cluster B) syncs
> it down → CloudNativePG provisions it → status **and** the connection Secret sync back up → a live
> `SELECT version()` returns **PostgreSQL 15.18**. See **[Verified live runbook](#verified-live-runbook)**
> for the exact commands and **[Troubleshooting](#troubleshooting)** for the gaps hit on the way.
> The control-plane side (the `postgresql.cnpg.io` APIExport, portal registration, account
> `APIBinding`) lives on the `feat/msp-postgres-localsetup` branch of the **helm-charts** repo
> (Workstream A).

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
`APIExportEndpointSlice` virtual-workspace URL that A's kcp advertises (kcp shard
`virtualWorkspaceURL: https://root.kcp.localhost:8443/`). The hostname **must** be
`root.kcp.localhost` — cluster A fronts kcp with an Istio gateway that routes by SNI, and only that
name has a TLSRoute. Since `root.kcp.localhost` would otherwise resolve to `127.0.0.1` inside a pod,
the agent's `hostAliases` (in `config/syncagent/values.yaml`) maps it to a host-reachable IP.

> **Verified bridge value (Docker Desktop).** local-setup publishes A's gateway on **`127.0.0.1:8443`**
> (loopback only — `docker port platform-mesh-control-plane` shows `31000/tcp -> 127.0.0.1:8443`).
> The working `hostAliases` target is therefore **`host.docker.internal`'s IPv4 = `192.168.65.254`**,
> which Docker Desktop forwards to the host loopback where A's `:8443` lives. The `kind` bridge
> gateway (`172.18.0.1`) does **not** work here, because a loopback-bound port is unreachable via the
> bridge interface. **`task syncagent:install` auto-resolves this per host** —
> `docker exec msp-postgres-backing-control-plane getent ahostsv4 host.docker.internal` — and
> overrides the hostAlias via `--set`, so no manual IP-hunting is needed; `config/syncagent/values.yaml`
> keeps `192.168.65.254` as the fallback (used only if resolution fails or for a manual `helm install`).

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

## Verified live runbook

The exact sequence proven on **2026-05-27** (Docker Desktop, macOS arm64), across two repos:
`helm-charts` (cluster A) and this directory (cluster B). `<helm-charts>` = your helm-charts checkout.

### 1 · Cluster A — Platform Mesh local-setup (control plane)

From the **helm-charts** repo on branch `feat/msp-postgres-localsetup`:

```sh
task local-setup:example-data    # kind cluster A + kcp + portal + the postgres-provider example-data
```

Stands up kcp at `https://localhost:8443`, writes the admin kubeconfig to
`<helm-charts>/.secret/kcp/admin.kubeconfig`, and creates ws `root:providers:postgres-provider` with
APIExport `postgresql.cnpg.io` (+ ContentConfiguration `postgres-ui` + ProviderMetadata).

> **Gap hit — now fixed in-branch (#11).** The postgres `extraProviderConnections` entry makes the
> platform-mesh-operator mint a kubeconfig Secret into a **kind namespace `postgres-provider`** that
> nothing else creates, so `PlatformMesh` stalls at `ProvidersecretSubroutine: namespaces
> "postgres-provider" not found` and never goes `Ready`. The branch now creates that namespace; if you
> hit it on an older checkout, `kubectl --context kind-platform-mesh create namespace postgres-provider`
> (the operator then generates the Secret and `PlatformMesh` reconciles to `Ready` within ~1 reconcile).
> httpbin avoids this because its namespace is created by its in-cluster operator chart; postgres has none.

Confirm A is healthy:

```sh
kubectl --context kind-platform-mesh -n platform-mesh-system get platformmesh   # READY=True
```

### 2 · Cluster B — backing data plane (this directory)

```sh
task kind:up            # create kind cluster msp-postgres-backing (shares the 'kind' docker network)
task cnpg:install       # CloudNativePG v1.29.1
# (the hostAliases IP for root.kcp.localhost is auto-resolved per host by syncagent:install; no
#  manual values.yaml edit is needed — see the "Verified bridge value" note above)
task syncagent:kubeconfig   # derive provider-ws kubeconfig (root.kcp.localhost:8443, insecure) → Secret in B
task syncagent:install      # helm-install api-syncagent v0.6.0  (waits for Deployment Ready)
task syncagent:publish      # PublishedResource + RBAC → agent fills A's APIExport with the CNPG schema
```

After `syncagent:publish`, the agent has published APIResourceSchema `<hash>.clusters.postgresql.cnpg.io`
and APIExport `postgresql.cnpg.io` carries the schema **plus the 3 permissionClaims** (events,
namespaces, secrets). Agent logs show `Resolved APIExport postgresql.cnpg.io` → `Starting kcp Sync
Agent` with **no** `failed to get server groups` / `lookup … no such host` / TLS-SNI errors:

```sh
kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=60
```

### 3 · Bind + order + verify (consumer)

```sh
# Create a consumer workspace in cluster A (verified path used a standalone ws; an account ws under
# root:orgs is the portal-native case — see the note below):
KUBECONFIG=<helm-charts>/.secret/kcp/admin.kubeconfig \
  kubectl create-workspace consumer-pg --ignore-existing --server=https://localhost:8443/clusters/root

task bind   CONSUMER_WS=root:consumer-pg   # APIBinding → Bound + all 3 claims Accepted + clusters served
task order  CONSUMER_WS=root:consumer-pg   # Cluster pg-demo (PostgreSQL 15) in the consumer ws
task verify CONSUMER_WS=root:consumer-pg   # full e2e proof
```

**Verified result:** `✅ E2E PASS` (12/12 checks) — Cluster synced **down** to B (~3 s), CNPG
provisioned `pg-demo-1` (Ready), status + connection Secret `pg-demo-app` synced **back** to the
consumer (byte-identical), and the live query returned **`PostgreSQL 15.18 … on aarch64`**.

> `verify` (and `order`) run `kubectl ws <CONSUMER_WS>` against the admin kubeconfig, leaving its
> current context on the consumer ws — reset with
> `KUBECONFIG=<helm-charts>/.secret/kcp/admin.kubeconfig kubectl ws :root`.

### Portal ordering (account-native path)

The verified loop above uses **kubectl**. Ordering via the **portal** additionally requires:
1. A real **account** workspace (portal onboarding under `root:orgs:<org>:<account>`), whose
   `extraDefaultAPIBindings` auto-binds `postgresql.cnpg.io` — then `task bind` *patches* that
   auto-binding to accept the 3 claims (instead of applying `config/kcp/apibinding.yaml`).
2. An **`APIExportPolicy`** for `postgresql.cnpg.io` in `root:orgs` (mirroring httpbin's
   `example-data/root/orgs/apiexportpolicy.yaml`, `allowPathExpressions: [:root:orgs:*]`) so the
   org-level auto-bind is permitted. **Now in the branch** (`example-data/root/orgs/apiexportpolicy-postgres.yaml`)
   and **verified live**: with it applied, an account workspace's auto-binding to `postgresql.cnpg.io`
   reaches `Bound`, `task bind` patches the 3 claims to `PermissionClaimsApplied=True`, and
   `clusters.postgresql.cnpg.io` is served (and the gateway regenerates the account's schema). The
   standalone-ws path in §3 uses an admin-applied binding that bypasses this policy.
3. The Luigi create-form (ContentConfiguration `postgres-ui`, already applied) exposing the PG-15 +
   storage fields.

---

## Explore it yourself

After cluster A (`task local-setup:example-data`) + cluster B (the `task` sequence above) + a portal
order, the environment is left **running** for hands-on exploration (the #12 validation deliberately
skips the final `task down`). Values below are from the verified #12 run.

### Portal (UI)

- **URL:** <https://portal.localhost:8443> (redirects to Keycloak).
- **Login — self-registration (no pre-seeded user).** The #12 run registered **`username@sap.com` /
  `MyPass1234`** (first/last name `Firstname`/`Lastname`); log in with those, or click **Register** to
  create your own. (Keycloak admin console: <https://portal.localhost:8443/keycloak>, `keycloak-admin` /
  `admin`.)
- **Organization:** select/switch to **`default`** → the org portal opens at
  <https://default.portal.localhost:8443/home>.
- **Account:** **`pgportal-acct`** (kcp path `root:orgs:default:pgportal-acct`).
- **Your Postgres instance:** in the account open **“Postgres Databases”** →
  `https://default.portal.localhost:8443/home/accounts/pgportal-acct/postgresql_cnpg_io_clusters` →
  the Cluster **`pg-portal`** (“Cluster in healthy state”). Order more with the **Create** button
  (PostgreSQL 15 image, storage size, instances).

### kubectl (CLI)

`KC=<helm-charts>/.secret/kcp/admin.kubeconfig` · `KB=<this-dir>/.kube/kind.kubeconfig`

- **Portal-ordered instance** (consumer = the account ws):

  ```sh
  KUBECONFIG=$KC kubectl ws root:orgs:default:pgportal-acct   # navigate (revert later: kubectl ws :root)
  KUBECONFIG=$KC kubectl -n default get cluster pg-portal -o wide
  KUBECONFIG=$KC kubectl -n default get secret pg-portal-app   # connection Secret synced back up
  ```

- **kubectl-ordered example instance** (standalone consumer ws `root:consumer-pg`): same commands with
  `kubectl ws root:consumer-pg` + `get cluster pg-demo` / `get secret pg-demo-app`.
- **Backing cluster B** (where the databases actually run):

  ```sh
  kubectl --kubeconfig $KB get clusters.postgresql.cnpg.io -A          # pg-demo + pg-portal
  kubectl --kubeconfig $KB -n default get pods,svc,secret -l cnpg.io/cluster=pg-portal
  ```

- **Live query** (PostgreSQL 15.x via the synced creds): `task verify CONSUMER_WS=root:consumer-pg`
  (drives a one-shot `psql` Job in B → `SELECT version()` → `PostgreSQL 15.18`), or run an equivalent
  Job against `pg-portal-rw` using the `pg-portal-app` Secret.

> **Tear down when done:** `task down` (cluster B) + `kind delete cluster --name platform-mesh` (cluster A).

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

## Troubleshooting

- **`syncagent:kubeconfig` errors that cluster A's kubeconfig is missing** — stand up cluster A on
  the branch first; `KCP_KUBECONFIG` must point at a real `admin.kubeconfig`.
- **Agent can't reach kcp / `root.kcp.localhost` unresolvable or connection refused** — fix the
  `hostAliases` IP in `config/syncagent/values.yaml`. **On Docker Desktop the working value is
  `host.docker.internal`'s IPv4 = `192.168.65.254`** (forwards to the host loopback where local-setup
  publishes A's `:8443`). Discover it with
  `docker exec msp-postgres-backing-control-plane getent ahostsv4 host.docker.internal`, and confirm
  the path before installing the agent:
  `docker exec msp-postgres-backing-control-plane bash -c '</dev/tcp/host.docker.internal/8443' && echo OPEN`.
  The `kind` bridge gateway (`172.18.0.1`) only works if A's `:8443` is published on `0.0.0.0` — it
  is **not** by default (local-setup binds `127.0.0.1`).
- **TLS/routing errors despite reachability** — confirm the agent connects as `root.kcp.localhost`
  (SNI); any other name fails A's Istio SNI routing.
- **Secret never syncs back even though the binding is `Bound`** — this is the silent trap: the
  operator's auto-binding is claim-less. Run `task bind CONSUMER_WS=...` (gates on
  `PermissionClaimsApplied=True`, not just Bound). If the live binding presents the v1alpha2 claim
  shape (`selector.matchAll`) the script falls back to it automatically; inspect with
  `kubectl --kubeconfig "$KCP_KUBECONFIG" --server="https://root.kcp.localhost:8443/clusters/$CONSUMER_WS" get apibinding <name> -o yaml`.
- **Inspect the agent:**
  `kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=80`
- **Cluster A `PlatformMesh` never `Ready`; `ProvidersecretSubroutine: namespaces "postgres-provider" not found`** —
  the kind namespace `postgres-provider` is missing (see the runbook §1 gap). The branch creates it;
  otherwise `kubectl --context kind-platform-mesh create namespace postgres-provider` and wait one reconcile.
- **Consumer `APIBinding` won't bind in an *account* workspace (`root:orgs:…`)** — the
  `APIExportPolicy` permitting `:root:orgs:*` to bind `postgresql.cnpg.io` is required (Workstream A,
  tracked separately). The standalone-ws path in the runbook §3 uses an admin-applied binding and is
  unaffected.
- **`APIExportEndpointSlice postgresql.cnpg.io` shows no `status.endpoints`** — expected with
  api-syncagent v0.6.0: the slice reports `APIExportValid=True`/`PartitionValid=True` and the agent
  reaches the virtual workspace via its bootstrap server, so it does not warn/block on empty slice
  URLs (v0.4.x did). Not a fault; the sync loop still works.
- **`api-syncagent` pod crashloops with `failed to resolve APIExport … failed to get server groups`,
  or its Flux HelmRelease terminally `Stalled` (`install failed … context deadline exceeded`)** — seen
  when the example-data APIExports are created *late* (e.g. cluster A's `PlatformMesh` was stalled past
  the chart's install timeout). The agent recovers on a fresh restart once the APIExport exists; a
  clean from-scratch stand-up on the fixed branch avoids it entirely. (This was the in-A `orchestrate`
  agent during the namespace-gap incident — unrelated to this example's agent in cluster B.)

- **Postgres doesn't appear in the portal listing for an account** — the kubernetes-graphql-gateway
  surfaces a workspace's APIs from its **APIBindings**, regenerating the account's GraphQL schema on
  every bind event. The listener runs with `--anchor-resource=true` (the chart default), which matches
  **all** bindings, so `clusters.postgresql.cnpg.io` surfaces automatically once the account's
  APIBinding to `postgresql.cnpg.io` is `Bound`. **Load-bearing nuance:** do NOT "fix" the operator's
  `anchorResource` key to a named value — that activates a `contains("platform-mesh.io")` filter which
  would **exclude** `cnpg.io` and hide Postgres from the portal. The only precondition is the account
  binding reaching `Bound` (verified live: the account auto-bind + `task bind` patch → Bound + 3 claims
  + `clusters.postgresql.cnpg.io` served, and the gateway regenerated the account-ws schema).

---

## Documentation references

The integration follows the upstream Platform Mesh docs (current at
[platform-mesh.io](https://platform-mesh.io)); the most relevant pages:

- **`concepts/integration/api-syncagent.md`** — the api-syncagent model: outbound connection to kcp,
  `APIExport`/`APIExportEndpointSlice`, `PublishedResource`, related-object sync, permissionClaims.
- **`tutorials/provider-quick-start.md`** — publishing a provider API into kcp and ordering it from a
  consumer workspace (the passthrough pattern this example uses for CNPG's `Cluster`).
- **`how-to-guides/set-up-platform-mesh-locally.md`** — the local-setup (cluster A): kind, kcp behind
  the front-proxy/Istio gateway on `:8443`, `--example-data`, and the `kubectl-ws`/`kubectl-kcp` plugins.
