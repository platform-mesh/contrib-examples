# msp-mongodb-multiclusterruntime — MongoDB as an orderable service via custom syncher

This example turns **MongoDB into a self-service database** on a [kcp](https://kcp.io) control plane using a **custom syncher** built with [multiclusterruntime](https://github.com/kcp-dev/multiclusterruntime).
A consumer creates a `MongoDBCommunity` object in their kcp workspace; the custom syncher syncs it to a kind cluster where the **MongoDB Community Operator** provisions a real MongoDB ReplicaSet. Status flows back to the consumer. See [`docs/architecture.md`](docs/architecture.md) for the full flow diagram.

> **Note:** This example is different from `msp-postgres-kcp-only` and `msp-httpbin-operator`:
> - kcp runs **inside** the kind cluster (not as a host process)
> - Uses a **custom syncher** instead of [api-syncagent](https://github.com/kcp-dev/api-syncagent)
> - Demonstrates building a CRD-specific sync solution

**Matched stack:** kcp `0.16.0` (in-cluster) · MongoDB Community Operator `0.13.0` · syncher `sha-81430d4`

---

## Topology — where each piece runs

In this example **kcp runs inside the kind cluster** as a helm-deployed workload. The syncher (also in kind) connects to kcp via the in-cluster service.

```text
KIND CLUSTER
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────────────────────────────┐ │
│  │ kcp namespace    │    │ mongodb namespace                       │ │
│  │                  │    │                                         │ │
│  │  kcp (pods)      │◄───│  multiclusterruntime syncher            │ │
│  │  etcd            │    │  MongoDB Community Operator             │ │
│  │  front-proxy     │    │  MongoDB ReplicaSet pods                │ │
│  │                  │    │                                         │ │
│  └─────────────────┘    └─────────────────────────────────────────┘ │
│         ▲                                                           │
│         │ port 31443 -> host 8443                                   │
└─────────│───────────────────────────────────────────────────────────┘
          │
    HOST: https://kcp.localhost:8443 (*.localhost resolves to 127.0.0.1 per RFC 6761)
```

---

## Prerequisites

| Tool | Notes |
|------|-------|
| `docker` | Docker Desktop or Docker Engine |
| `kind` | Any recent release |
| `kubectl` | Plus the `kubectl-kcp` plugin (`kubectl ws`) for workspace navigation |
| `helm` | v3 |
| `task` | [Taskfile](https://taskfile.dev) runner — `brew install go-task` |

No `/etc/hosts` entry required — `*.localhost` resolves to `127.0.0.1` per [RFC 6761](https://tools.ietf.org/html/rfc6761).

---

## Quickstart

```sh
task up       # kind cluster with kcp, MongoDB operator, syncher, workspaces, binding
task order    # order a MongoDB (MongoDBCommunity example-mongodb) in the consumer workspace
task verify   # prove: MongoDB Running in kind, status synced back to kcp
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
| 2 | `kind:up` | Create kind cluster with port mapping; install cert-manager + kcp via helm |
| 3 | `kcp:setup` | Wait for kcp; create `root:mongodb` + `root:consumer` workspaces; apply APIResourceSchema + APIExport |
| 4 | `mongodb-operator:install` | Helm-install MongoDB Community Operator `0.13.0` into kind |
| 5 | `provider:bind` | Create APIBinding in consumer workspace; assert MongoDBCommunity API is served |
| 6 | `syncher:kubeconfig` | Build kcp kubeconfig (virtual workspace URL); store as Secret |
| 7 | `syncher:install` | Deploy the multiclusterruntime syncher |

Expected finish: no errors, and `kubectl ws root:consumer` shows the `MongoDBCommunity` API.

### 2. `task order` — order a MongoDB

```sh
task order
```

Applies `config/samples/mongodb.yaml` to the consumer workspace (`root:consumer`).
This creates `MongoDBCommunity/example-mongodb` in namespace `mongodb`. The syncher picks it up
and creates the matching CR in kind where the MongoDB Operator provisions a ReplicaSet.

### 3. `task verify` — prove the loop is closed

```sh
task verify
```

The end-to-end check (`test/e2e.sh`) asserts:
- `MongoDBCommunity/example-mongodb` exists in the consumer workspace
- The syncher synced it to kind
- MongoDB pods are `Running` (takes ~2-3 minutes for provisioning)
- `status.phase: Running` and `status.version: 6.0.5` are synced back to kcp

### 4. `task down` — tear down

```sh
task down
```

Deletes the kind cluster and all kubeconfig files.

---

## Monitoring live state

```sh
task status   # non-destructive: shows kind nodes, kcp pods, MongoDB operator, syncher
```

---

## Troubleshooting

### kcp not reachable from host

Test connectivity:
```sh
curl -k https://kcp.localhost:8443/readyz
```

### Syncher not syncing

Check the syncher logs:
```sh
kubectl --kubeconfig .kube/kind.kubeconfig -n mongodb logs -l app=example-mongodb-mcr-controller --tail=60
```

Common issues:
- kcp kubeconfig Secret not created (`task syncher:kubeconfig`)
- Virtual workspace URL not reachable (check `hostAliases` in the deployment)

### MongoDB stuck in Pending

The MongoDB Community Operator needs time to provision. Check operator logs:
```sh
kubectl --kubeconfig .kube/kind.kubeconfig -n mongodb logs -l name=mongodb-kubernetes-operator --tail=60
```

---

## Per-target reference

| Target | Script / Entrypoint | Owner | Idempotent? | Notes |
|--------|-------------------|-------|-------------|-------|
| `tools:check` | `hack/tools-check.sh` | k8s-expert | ✅ | Fails fast if a required CLI is missing |
| `kind:up` | `hack/kind-up.sh` | k8s-expert | ✅ | Creates kind + installs cert-manager + kcp |
| `kind:down` | `hack/kind-down.sh` | k8s-expert | ✅ | No-op if cluster absent |
| `kcp:setup` | `hack/kcp-setup.sh` | kcp-expert | ✅ | Creates workspaces + APIExport |
| `mongodb-operator:install` | `hack/mongodb-operator-install.sh` | mongodb-expert | ✅ | Helm install |
| `syncher:kubeconfig` | `hack/syncher-kubeconfig.sh` | syncher-expert | ✅ | Stores VW kubeconfig as Secret |
| `syncher:install` | `hack/syncher-install.sh` | syncher-expert | ✅ | `apply`; waits for rollout |
| `provider:bind` | `hack/provider-bind.sh` | kcp-expert | ✅ | APIBinding + assert API served |
| `order` | `hack/order.sh` | mongodb-expert | ✅ | `apply` — no-op if already exists |
| `verify` | `test/e2e.sh` | test-verifier | read-only | Fails if any assertion misses |
| `status` | inline | developer | read-only | Safe to run any time |
| `up` | orchestrates above | developer | ✅ | Sequential; restart after failure |
| `down` | orchestrates above | developer | ✅ | |

---

## Env vars contract

All `hack/` scripts receive the following env vars from `Taskfile.yml`:

| Var | Value | Purpose |
|-----|-------|---------|
| `KIND_KUBECONFIG` | `.kube/kind.kubeconfig` | kind cluster kubeconfig |
| `KCP_ADMIN_KUBECONFIG` | `.kcp/admin.kubeconfig` | kcp admin kubeconfig (root workspace) |
| `KCP_CONTROLLER_KUBECONFIG` | `.kcp/controller.kubeconfig` | kcp kubeconfig for the syncher (virtual workspace) |
| `KCP_HOSTNAME` | `kcp.localhost` | Hostname for kcp (*.localhost auto-resolves) |
| `KCP_EXTERNAL_PORT` | `8443` | Host-side port for kcp |
| `MONGODB_OPERATOR_VERSION` | `0.13.0` | Pinned MongoDB operator version |
| `SYNCHER_IMAGE` | `ghcr.io/platform-mesh/example-mongodb-multiclusterruntime:sha-81430d4` | Syncher container image |
| `KIND_CLUSTER` | `msp-mongodb` | kind cluster name |
| `PROVIDER_WS` | `root:mongodb` | kcp provider workspace |
| `CONSUMER_WS` | `root:consumer` | kcp consumer workspace |
| `ORDER_NAME` | `example-mongodb` | Name of the ordered `MongoDBCommunity` CR |
| `ORDER_NS` | `mongodb` | Namespace for the order |
| `TASKFILE_DIR` | _(repo root of this example)_ | Absolute path |

---

## When to use this approach

This example demonstrates a **custom syncher** built with multiclusterruntime. Use this approach when:
- You need custom sync logic beyond api-syncagent's capabilities
- You want to transform objects during sync
- You need special collision handling
- You're building a CRD-specific solution

For most use cases, [api-syncagent](https://github.com/kcp-dev/api-syncagent) is simpler and more feature-complete. See `msp-postgres-kcp-only` and `msp-httpbin-operator` for api-syncagent examples.
