# msp-httpbin-operator — HttpBin as an orderable service on Platform Mesh (kcp)

This example turns **HttpBin into a self-service HTTP testing endpoint** on a [kcp](https://kcp.io) control plane.
A consumer creates an `HttpBin` object in their own kcp workspace; the [kcp api-syncagent](https://github.com/kcp-dev/api-syncagent) syncs it to a backing **kind** cluster where the **httpbin-operator** provisions a Deployment + Service running the httpbin container. Status flows back to the consumer. See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid flow diagram.

**Matched stack:** kcp `v0.31.2` · api-syncagent `v0.6.0` · httpbin-operator `v0.6.2`

---

## Topology — where each piece runs

In this example **kcp runs locally as a process on your host — it is _not_ deployed inside
the kind cluster.** kcp is the *control plane* you order from; the kind cluster is the *service
cluster* where the operator and the actual httpbin pods run. They are separate processes/containers,
and the api-syncagent (running **inside** kind) dials **out** to kcp on the host.

```text
HOST                                       DOCKER — one kind container
┌───────────────────────────────┐        ┌─────────────────────────────────────┐
│ kcp  (control plane)           │        │ kind  "service cluster"             │
│  • bin/kcp start (local proc)  │        │  • httpbin-operator                 │
│  • state in ./.kcp/ (etcd)     │◄──────►│  • api-syncagent  ─ dials out ─────►│
│  • workspaces, APIExport       │ :6443  │  • httpbin pods                     │
│  • listens on 0.0.0.0:6443     │        │                                     │
└───────────────────────────────┘        └─────────────────────────────────────┘
   advertises host.docker.internal:6443   ◄─ the in-kind agent reaches kcp here
```

---

## Prerequisites

| Tool | Notes |
|------|-------|
| `docker` | Docker Desktop — provides `host.docker.internal` for kcp↔kind connectivity |
| `kind` | Any recent release |
| `kubectl` | Plus the `kubectl-kcp` plugin (`kubectl ws`) for workspace navigation |
| `helm` | v3 |
| `task` | [Taskfile](https://taskfile.dev) runner — `brew install go-task` |
| `yq` | Required by `kcp-start.sh` and `kcp-workspaces.sh` to rewrite kubeconfig server URLs — `brew install yq` |
| `curl` | For HTTP testing in `task verify` |
| `kcp` binary | **Downloaded automatically** by `task tools:kcp` into `bin/` — no global install needed |

---

## Quickstart

```sh
task up       # pin kcp, start kcp + kind + httpbin-operator + api-syncagent, publish & bind
task order    # order an HttpBin (httpbin-demo) in the consumer workspace
task verify   # prove: pod Ready in kind, status synced back to kcp, live HTTP test
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
| 4 | `kcp:workspaces` | Create `root:msp:httpbin-provider` + `root:msp:customer-a`; apply empty `APIExport` |
| 5 | `kind:up` | Create kind cluster `msp-httpbin`; kubeconfig at `.kube/kind.kubeconfig` |
| 6 | `httpbin-operator:install` | Install httpbin-operator CRDs + deployment; waits for rollout |
| 7 | `syncagent:kubeconfig` | Build provider-workspace kubeconfig; store as a `Secret` in kind (`kcp-system`) |
| 8 | `syncagent:install` | Helm-install api-syncagent `v0.6.0` into kind (`kcp-system` namespace) |
| 9 | `syncagent:publish` | Apply `PublishedResource` + RBAC; agent generates `APIResourceSchema` + fills `APIExport` |
| 10 | `provider:bind` | Create `APIBinding` in consumer workspace; assert `httpbins.orchestrate.platform-mesh.io` is served |

Expected finish: no errors, and `kubectl ws root:msp:customer-a` shows the `HttpBin` API in `kubectl api-resources`.

### 2. `task order` — order an HttpBin

```sh
task order
```

Applies `config/samples/order-httpbin.yaml` to the consumer workspace (`root:msp:customer-a`).
This creates `HttpBin/httpbin-demo` in namespace `default`. The api-syncagent immediately picks it up
and creates the matching `HttpBin` in kind where the httpbin-operator reconciles it.

### 3. `task verify` — prove the loop is closed

```sh
task verify
```

The end-to-end check (`test/e2e.sh`) asserts:
- `HttpBin/httpbin-demo` synced to kind
- Deployment is `Ready` in kind
- `status.ready: true` is synced back to the kcp consumer workspace
- A live `curl` to the httpbin `/get` endpoint returns valid JSON

### 4. `task down` — tear down

```sh
task down
```

Stops kcp first (so the syncagent's reconciler drains), then deletes the kind cluster.
Kubeconfig files in `.kcp/` and `.kube/` are cleaned up by the scripts.

---

## Monitoring live state

```sh
task status   # non-destructive: shows kcp PID, kind nodes, httpbin-operator deploy, syncagent deploy
```

---

## Troubleshooting

### kcp ↔ kind connectivity

**The main risk in this setup** is that kcp (a **local host process** — see [Topology](#topology--where-each-piece-runs)) must serve URLs reachable from _inside_ kind pods (where the api-syncagent runs).

**Approach used here:** kcp binds `0.0.0.0` and **advertises** `host.docker.internal` (via `--shard-base-url`); Docker Desktop injects that hostname into every container, so the in-kind agent reaches the host. The syncagent kubeconfig points at `https://host.docker.internal:<kcp-port>` with `insecure-skip-tls-verify`.

If you see `dial tcp: lookup host.docker.internal: no such host` in the syncagent logs:
- Ensure you are using Docker Desktop (not plain `dockerd` / colima without the compat layer).
- Alternative fallback: see the `hostAliases` section in `config/syncagent/values.yaml`.

### kcp fails to start

```sh
# Check whether port 6443 is already in use:
lsof -iTCP:6443 -sTCP:LISTEN
# Kill a stale kcp process:
pkill -f 'kcp start'
```

### api-syncagent pod is CrashLoopBackOff

```sh
# Tail logs from the agent pod(s):
kubectl --kubeconfig .kube/kind.kubeconfig -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=60
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
| `httpbin-operator:install` | `hack/httpbin-operator-install.sh` | httpbin-expert | ✅ | `apply`; waits for rollout |
| `syncagent:kubeconfig` | `hack/syncagent-kubeconfig.sh` | syncagent-expert | ✅ | Stores provider kubeconfig as `Secret` in kind |
| `syncagent:install` | `hack/syncagent-install.sh` | syncagent-expert | ✅ | Helm install/upgrade |
| `syncagent:publish` | `hack/syncagent-publish.sh` | syncagent-expert | ✅ | `PublishedResource` + RBAC; triggers schema generation |
| `order` | `hack/order.sh` | httpbin-expert | ✅ | `apply` — no-op if `HttpBin/httpbin-demo` already exists |
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
| `HTTPBIN_OPERATOR_VERSION` | `v0.6.2` | Pinned httpbin-operator version |
| `HTTPBIN_OPERATOR_IMAGE` | `ghcr.io/platform-mesh/example-httpbin-operator:v0.6.2` | Container image for the operator |
| `KIND_CLUSTER` | `msp-httpbin` | kind cluster name |
| `KIND_CONTEXT` | `kind-msp-httpbin` | kubectl context name for the kind cluster |
| `PROVIDER_WS` | `root:msp:httpbin-provider` | kcp provider workspace |
| `CONSUMER_WS` | `root:msp:customer-a` | kcp consumer workspace |
| `ORDER_NAME` | `httpbin-demo` | Name of the ordered `HttpBin` CR |
| `ORDER_NS` | `default` | Namespace of the ordered `HttpBin` in the consumer workspace |
| `KCP_EXTERNAL_HOST` | `host.docker.internal` | kcp hostname reachable from inside kind |
| `TASKFILE_DIR` | _(repo root of this example)_ | Absolute path; use to build relative paths in scripts |
