# platform-mesh/contrib-examples

> [!WARNING]
> **Work in progress — example code only.** This is an examples repository
> associated with Platform Mesh. The code here is **not** officially maintained,
> has no support or backwards-compatibility guarantees, and is **not** part of
> the Platform Mesh release process. Use the examples as starting points, not
> as production references.

A collection of runnable **example MSPs** (managed services) for [Platform Mesh](https://github.com/platform-mesh) on
[kcp](https://kcp.io). Each example turns a piece of off-the-shelf infrastructure into a self-service,
orderable API on a kcp control plane — using the [api-syncagent](https://github.com/kcp-dev/api-syncagent)
to bridge a consumer's kcp workspace and the cluster where the operator actually runs.

Each example lives in its own top-level `msp-<service>/` directory and is fully self-contained
(its own `Taskfile.yml`, `hack/` scripts, `config/` manifests, `test/e2e.sh`, and `README.md`).
**Run every command from inside that directory** — there is no top-level build.

## Examples

| Example | What it shows | Control plane |
|---------|---------------|---------------|
| [`msp-postgres-kcp-only/`](msp-postgres-kcp-only/) | PostgreSQL as an orderable service via CloudNativePG — passthrough of the native `Cluster` API, with status + connection `Secret` synced back to the consumer | Standalone: kcp as a local host process + a kind cluster for the data plane |
| [`msp-postgres-localsetup/`](msp-postgres-localsetup/) | Same Postgres-as-a-service loop, pinned to PostgreSQL 15, but wired into an existing Platform Mesh deployment — agent + CNPG run in a *second* kind cluster | Platform Mesh [`local-setup`](https://github.com/platform-mesh/local-setup) (kcp + portal + Keycloak) |

Each example's README has its own quickstart, architecture diagram (`docs/architecture.md`),
per-target reference, and troubleshooting section.

## Adding a new MSP

Mirror the layout of an existing example:

```text
msp-<service>/
├── Taskfile.yml         # thin orchestrator; exports all config as env vars
├── README.md            # quickstart + per-target reference + troubleshooting
├── hack/                # bash scripts (one per task); set -euo pipefail; idempotent
├── config/              # YAML manifests (apiexport, apibinding, publishedresource, samples, ...)
├── test/e2e.sh          # end-to-end proof: order → reconcile → status/Secret syncs back
└── docs/architecture.md # Mermaid flow of the sync loop
```

See [`CLAUDE.md`](CLAUDE.md) for the shared conventions every example follows
(Taskfile-as-orchestrator, env-var contract, ownership headers, idempotent scripts,
two-kubeconfig discipline, validation commands).
