# msp-postgres-kcp-only — PostgreSQL as an orderable service on Platform Mesh (kcp)

This example turns **PostgreSQL into a self-service database** on a [kcp](https://kcp.io) control plane.
A consumer creates a CloudNativePG `Cluster` object in their own kcp workspace; the [kcp api-syncagent](https://github.com/kcp-dev/api-syncagent) syncs it to a backing **kind** cluster where the **CloudNativePG** operator provisions a real PostgreSQL instance. Status and the generated connection `Secret` flow back to the consumer — no custom operator required. See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid flow diagram.

**Matched stack:** kcp `v0.31.2` · api-syncagent `v0.6.0` · CloudNativePG `v1.29.1`

---

## Topology — where each piece runs

In this example **kcp runs locally as a process on your host (macOS) — it is _not_ deployed inside
the kind cluster.** kcp is the *control plane* you order from; the kind cluster is the *service
cluster* where the operator and the actual databases run. They are separate processes/containers,
and the api-syncagent (running **inside** kind) dials **out** to kcp on the host.

```text
HOST (macOS)                               DOCKER — one kind container
┌───────────────────────────────┐        ┌─────────────────────────────────────┐
│ kcp  (control plane)           │        │ kind  "service cluster"             │
│  • bin/kcp start (local proc)  │        │  • CloudNativePG operator           │
│  • state in ./.kcp/ (etcd)     │◄──────►│  • api-syncagent  ─ dials out ─────►│
│  • workspaces, APIExport       │ :6443  │  • Postgres pods + PVCs             │
│  • listens on 0.0.0.0:6443     │        │                                     │
└───────────────────────────────┘        └─────────────────────────────────────┘
   advertises host.docker.internal:6443   ◄─ the in-kind agent reaches kcp here
```

Because the agent (container) and kcp (host) are in different network namespaces, `kcp:start`
launches kcp with `--bind-address=0.0.0.0 --shard-base-url=https://host.docker.internal:6443`, so
the serving-cert SAN **and** the `APIExportEndpointSlice` virtual-workspace URL use a hostname the
container can reach (`host.docker.internal`, injected by Docker Desktop). The host-side
`admin.kubeconfig` is rewritten to `127.0.0.1:6443` for local CLI use.

> **Local vs. hosted kcp.** Running kcp locally is a convenience for this single-machine demo. The
> api-syncagent is explicitly designed to connect to a **remote** kcp, so in a real Platform Mesh
> deployment kcp is a hosted/clustered control plane and only the api-syncagent + operator +
> databases live in the service cluster. Pointing this example at a hosted kcp (instead of the local
> `bin/kcp`) needs no change to the publish / order / bind flow — only the kcp endpoint and
> kubeconfig differ.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| `docker` | Docker Desktop (macOS) — provides `host.docker.internal` for kcp↔kind connectivity |
| `kind` | Any recent release |
| `kubectl` | Plus the `kubectl-kcp` plugin (`kubectl ws`) for workspace navigation |
| `helm` | v3 |
| `task` | [Taskfile](https://taskfile.dev) runner — `brew install go-task` |
| `yq` | Required by `kcp-start.sh` and `kcp-workspaces.sh` to rewrite kubeconfig server URLs — `brew install yq` |
| `psql` | Optional; only needed for the live `SELECT version()` in `task verify` |
| `kcp` binary | **Downloaded automatically** by `task tools:kcp` into `bin/` — no global install needed |

---

## Quickstart

```sh
task up       # pin kcp, start kcp + kind + CNPG + api-syncagent, publish & bind
task order    # order a Postgres (Cluster pg-demo) in the consumer workspace
task verify   # prove: pod Ready in kind, status + Secret synced back to kcp
task down     # tear everything down
```

Run `task` (no args) or `task --list` to see all available targets.

---

## Detailed walkthrough

### 1. `task up` — bring up the full stack

`task up` runs the following steps **in order** (each script is idempotent — restarting after a failed step is safe):

| Step | Target | What it does |
|------|--------|--------------|
| 1 | `tools:check` | Verify `kubectl`, `kind`, `docker`, `helm` are on `$PATH` |
| 2 | `tools:kcp` | Download kcp `v0.31.2` into `bin/` (skipped if already present) |
| 3 | `kcp:start` | Start kcp locally; kubeconfig written to `.kcp/admin.kubeconfig` |
| 4 | `kcp:workspaces` | Create `root:msp:postgres-provider` + `root:msp:customer-a`; apply empty `APIExport` |
| 5 | `kind:up` | Create kind cluster `msp-postgres`; kubeconfig at `.kube/kind.kubeconfig` |
| 6 | `cnpg:install` | Install CloudNativePG `v1.29.1` via manifest; waits for rollout |
| 7 | `syncagent:kubeconfig` | Build provider-workspace kubeconfig; store as a `Secret` in kind (`kcp-system`) |
| 8 | `syncagent:install` | Helm-install api-syncagent `v0.6.0` into kind (`kcp-system` namespace) |
| 9 | `syncagent:publish` | Apply `PublishedResource` + RBAC; agent generates `APIResourceSchema` + fills `APIExport` |
| 10 | `provider:bind` | Create `APIBinding` in consumer workspace; assert `clusters.postgresql.cnpg.io` is served |

Expected finish: no errors, and `kubectl ws root:msp:customer-a` shows the `Cluster` API in `kubectl api-resources`.

### 2. `task order` — order a Postgres

```sh
task order
```

Applies `config/samples/order-cluster.yaml` to the consumer workspace (`root:msp:customer-a`).
This creates `Cluster/pg-demo` in namespace `default`. The api-syncagent immediately picks it up
and creates the matching `Cluster` in kind where CNPG reconciles it.

> **Goal-1 naming simplification:** `config/syncagent/publishedresource-cluster.yaml` sets a `naming`
> block that preserves the consumer's name and namespace on the kind cluster. So on kind the objects
> are predictably `Cluster/pg-demo`, pods `pg-demo-1`, Secret `pg-demo-app` — matching what you see
> in the consumer workspace. **This is intentional for the single-consumer goal 1 demo only.** The
> api-syncagent's default behaviour applies anti-collision name hashing, which is required for
> multi-consumer (goal 2). The `naming` block must be removed before scaling to multiple consumers
> to avoid name collisions on kind.

### 3. `task verify` — prove the loop is closed

```sh
task verify
```

The end-to-end check (`test/e2e.sh`) asserts:
- `pg-demo-1` pod is `Ready` in kind (within ~60 s)
- `status.readyInstances: 1` is synced back to the kcp consumer workspace
- `Secret/pg-demo-app` (connection credentials) is synced to the consumer workspace
- A live `SELECT version();` via `psql` returns the PostgreSQL version string

### 4. `task down` — tear down

```sh
task down
```

Stops kcp first (so the syncagent's reconciler drains), then deletes the kind cluster.
Kubeconfig files in `.kcp/` and `.kube/` are cleaned up by the scripts.

---

## Monitoring live state

```sh
task status   # non-destructive: shows kcp PID, kind nodes, CNPG deploy, syncagent deploy
```

---

## Troubleshooting

### kcp ↔ kind connectivity

**The main risk in this setup** is that kcp (a **local host process** — see [Topology](#topology--where-each-piece-runs)) must serve URLs reachable from _inside_ kind pods (where the api-syncagent runs).

**Approach used here:** kcp binds `0.0.0.0` and **advertises** `host.docker.internal` (via `--shard-base-url`); Docker Desktop injects that hostname into every container, so the in-kind agent reaches the host. The syncagent kubeconfig points at `https://host.docker.internal:<kcp-port>` with `insecure-skip-tls-verify`.

If you see `dial tcp: lookup host.docker.internal: no such host` in the syncagent logs:
- Ensure you are using Docker Desktop (not plain `dockerd` / colima without the compat layer).
- Confirm Docker Desktop → Settings → Resources → Network has "Allow the default Docker socket to be used" enabled.
- Alternative fallback (not needed with Docker Desktop): run the api-syncagent as a host process instead of a pod, pointing it at `127.0.0.1:<kcp-port>`. Contact the team lead if you need to activate this variant.

### kcp fails to start

```sh
# Check whether port 6443 is already in use:
lsof -iTCP:6443 -sTCP:LISTEN
# Kill a stale kcp process:
pkill -f 'kcp start'
```

### kind cluster exists but nodes are NotReady

```sh
kubectl --kubeconfig .kube/kind.kubeconfig get nodes
# If stuck, recreate:
task kind:down && task kind:up
```

### api-syncagent pod is CrashLoopBackOff

The Helm release name is `kcp-api-syncagent` (chart `kcp/api-syncagent`). The chart sets `app.kubernetes.io/name` to the fullname (= release name), so the Deployment is named `kcp-api-syncagent` and carries the label `app.kubernetes.io/name=kcp-api-syncagent`:

```sh
# Find the deployment:
kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system get deploy -l app.kubernetes.io/name=kcp-api-syncagent

# Tail logs from the agent pod(s):
kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=60
```

Common causes: the provider-workspace kubeconfig Secret is missing or stale (`task syncagent:kubeconfig` again), or the `APIExport` was not yet populated before install (`task syncagent:publish` idempotently fills it).

### `task verify` fails on `pg-demo-1 not Ready`

CNPG provisions storage via a `PersistentVolumeClaim`. Ensure Docker Desktop has enough disk space allocated (≥ 10 GB free). Inspect events:

```sh
kubectl --kubeconfig .kube/kind.kubeconfig -n default describe cluster pg-demo
kubectl --kubeconfig .kube/kind.kubeconfig -n default get pvc
```

---

## Per-target reference

| Target | Script / Entrypoint | Owner | Idempotent? | Notes |
|--------|-------------------|-------|-------------|-------|
| `tools:check` | `hack/tools-check.sh` | k8s-expert | ✅ | Fails fast if a required CLI is missing |
| `tools:kcp` | `hack/tools-kcp.sh` | kcp-expert | ✅ | Skipped (`status:`) when `bin/kcp` already exists |
| `kcp:start` | `hack/kcp-start.sh` | kcp-expert | ✅ | Writes `.kcp/admin.kubeconfig` |
| `kcp:stop` | `hack/kcp-stop.sh` | kcp-expert | ✅ | No-op if kcp not running |
| `kcp:workspaces` | `hack/kcp-workspaces.sh` | kcp-expert | ✅ | Skip-if-exists for workspaces |
| `provider:bind` | `hack/provider-bind.sh` | kcp-expert | ✅ | Asserts `APIBinding` + waits for API to be served |
| `kind:up` | `hack/kind-up.sh` | k8s-expert | ✅ | Skip-if-exists; exports `.kube/kind.kubeconfig` |
| `kind:down` | `hack/kind-down.sh` | k8s-expert | ✅ | No-op if cluster absent |
| `cnpg:install` | `hack/cnpg-install.sh` | postgres-expert | ✅ | `apply --server-side`; waits for rollout |
| `syncagent:kubeconfig` | `hack/syncagent-kubeconfig.sh` | syncagent-expert | ✅ | Stores provider kubeconfig as `Secret` in kind |
| `syncagent:install` | `hack/syncagent-install.sh` | syncagent-expert | ✅ | Helm install/upgrade |
| `syncagent:publish` | `hack/syncagent-publish.sh` | syncagent-expert | ✅ | `PublishedResource` + RBAC; triggers schema generation |
| `order` | `hack/order.sh` | postgres-expert | ✅ | `apply` — no-op if `Cluster/pg-demo` already exists |
| `verify` | `test/e2e.sh` | test-verifier | read-only | Fails if any assertion misses |
| `status` | inline | developer | read-only | Safe to run any time |
| `up` | orchestrates above | developer | ✅ | Sequential; restart after failure at any step |
| `down` | orchestrates above | developer | ✅ | kcp → kind order |

---

## Env vars contract

All `hack/` scripts receive the following env vars from `Taskfile.yml` — scripts **must not** hardcode any of these values:

| Var | Value | Purpose |
|-----|-------|---------|
| `KUBECONFIG` | `.kcp/admin.kubeconfig` | Default kubeconfig (kcp). kcp operations may use this. |
| `KCP_KUBECONFIG` | `.kcp/admin.kubeconfig` | Explicit alias for kcp kubeconfig |
| `KIND_KUBECONFIG` | `.kube/kind.kubeconfig` | **Must be used explicitly** for all `kubectl` ops against kind |
| `KCP_BIN` | `bin/kcp` | Path to the pinned kcp binary |
| `KCP_VERSION` | `v0.31.2` | Pinned kcp version |
| `SYNCAGENT_VERSION` | `0.6.0` | Pinned api-syncagent version |
| `CNPG_VERSION` | `1.29.1` | Pinned CNPG version |
| `KIND_CLUSTER` | `msp-postgres` | kind cluster name |
| `KIND_CONTEXT` | `kind-msp-postgres` | kubectl context name for the kind cluster |
| `PROVIDER_WS` | `root:msp:postgres-provider` | kcp provider workspace |
| `CONSUMER_WS` | `root:msp:customer-a` | kcp consumer workspace |
| `ORDER_NAME` | `pg-demo` | Name of the ordered CNPG `Cluster` CR |
| `ORDER_NS` | `default` | Namespace of the ordered `Cluster` in the consumer workspace |
| `KCP_EXTERNAL_HOST` | `host.docker.internal` | kcp hostname reachable from inside kind |
| `TASKFILE_DIR` | _(repo root of this example)_ | Absolute path; use to build relative paths in scripts |
