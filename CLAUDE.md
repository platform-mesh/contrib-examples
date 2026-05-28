# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`platform-mesh/examples` — a collection of runnable **example MSPs** (managed services) for
Platform Mesh (kcp). Each MSP is a self-contained example in its own top-level directory using the
`msp-<service>/` naming convention; the first is **`msp-postgres-kcp-only/`**, which turns PostgreSQL into a
self-service, orderable database on a kcp control plane. Work happens inside a single example
directory; **run every command from that directory.**

There is **no application/compiled code** here. An example MSP is a `Taskfile.yml` orchestrating
bash scripts (`hack/`) over YAML manifests (`config/`), with a bash end-to-end test (`test/e2e.sh`).
No Go module, no Makefile. A new MSP follows the same layout in a new `msp-*/` directory, and the
conventions below apply to all of them.

## Commands (run from `msp-postgres-kcp-only/`)

```sh
task            # list all targets (default)
task up         # stand up the whole stack: kcp + kind + CNPG + api-syncagent, then publish & bind
task order      # order a Postgres (Cluster pg-demo) in the consumer workspace
task verify     # end-to-end proof (test/e2e.sh): pod Ready, status+Secret synced back, live SELECT
task down       # tear down (kcp first, then kind)
task status     # non-destructive snapshot of live state
```

`task up` is a sequential, **idempotent** pipeline — re-running after a partial failure is safe.
Individual steps (`task kcp:start`, `task syncagent:install`, …) run standalone; see the
"Per-target reference" table in `msp-postgres-kcp-only/README.md`.

### Validating edits without standing up the stack

Editing scripts/manifests does not need a live cluster. The validation conventions documented in
`Taskfile.yml`'s header are: `shellcheck` on `hack/*.sh` + `test/e2e.sh`; `yamllint` on `config/`;
`helm template` for the api-syncagent chart against `config/syncagent/values.yaml`; and
`kubectl create --dry-run=client -f <manifest>` for built-in kinds.

Only the integration runner executes the live `up`/`order`/`verify`/`down` — they share **one** kcp
process and **one** kind cluster, so concurrent live runs corrupt shared state.

## Architecture

Read `msp-postgres-kcp-only/docs/architecture.md` (Mermaid flow) and `README.md` first. The essential model:

- **Two control planes.** kcp runs as a **local host binary** (pinned into `bin/`, state in `.kcp/`);
  the backing **kind** cluster runs in Docker and hosts the CloudNativePG (CNPG) operator and the
  api-syncagent pod.
- **The sync loop.** A consumer creates a CNPG `Cluster` in their kcp workspace → the api-syncagent
  (running in kind) syncs it **down** to kind → CNPG provisions real Postgres → status **and** the
  generated connection `Secret` sync **back up** to the consumer. No custom operator — consumers
  order CNPG's *native* `Cluster` API ("passthrough", goal 1).
- **kcp objects.** Provider workspace `root:msp:postgres-provider` holds an `APIExport` (shipped
  empty; the agent fills `latestResourceSchemas` + permissionClaims when the `PublishedResource` is
  applied on kind). Consumer workspace `root:msp:customer-a` holds an `APIBinding` to that export
  plus the ordered `Cluster`.
- **Pinned, matched stack — do not bump independently:** kcp `v0.31.2`, api-syncagent `v0.6.0`,
  CloudNativePG `v1.29.1`.

## Conventions that will trip you up

**Taskfile is a thin orchestrator with an ownership model.** Each task calls exactly one `hack/`
script; each script/manifest names a single "owner" in its header comment (a multi-author
convention — `kcp-expert`, `syncagent-expert`, etc.). Keep the boundary: put logic in the `hack/`
script, not in `Taskfile.yml`.

**Env-var contract.** `Taskfile.yml` exports all configuration (versions, workspace names,
kubeconfig paths, `KCP_EXTERNAL_HOST`, …) as env vars. Scripts **read** these and must **not**
hardcode the values — they keep `${VAR:-default}` fallbacks only for standalone runs. To change a
name/version, edit the `vars:` block in `Taskfile.yml`, not the scripts. Full table in README
"Env vars contract".

**Two kubeconfigs — be explicit.** `KUBECONFIG`/`KCP_KUBECONFIG` = `.kcp/admin.kubeconfig`
(rewritten by `kcp:start` to a host-reachable address like `127.0.0.1`). kind has a separate
`.kube/kind.kubeconfig` (`KIND_KUBECONFIG`). **Every `kubectl` against kind must pass
`--kubeconfig "$KIND_KUBECONFIG"`**; kcp ops use the default. The in-kind agent uses yet a third
kubeconfig (stored as a Secret) pointing at `host.docker.internal`.

**`kubectl ws` is a plugin.** Flags go *after* the subcommand, and `--kubeconfig` is rejected before
a plugin name — pass the kubeconfig via the `KUBECONFIG` env var instead (see `kcws()` in
`test/e2e.sh`).

**Connectivity is the crux of this example.** kcp must serve URLs reachable from inside kind pods.
It binds `0.0.0.0` and advertises `host.docker.internal` (Docker Desktop injects this hostname into
containers) via `--shard-base-url`. If the agent logs `lookup host.docker.internal: no such host`,
see README "Troubleshooting" and the `hostAliases` fallback in `config/syncagent/values.yaml`.

**All `hack/` scripts run `set -euo pipefail` and must stay idempotent** (skip-if-exists, `apply`,
no-op when already done).

**Two correctness traps that fail *silently*:**
- The `naming` block in `config/syncagent/publishedresource-cluster.yaml` is a **goal-1
  single-consumer simplification** that preserves consumer names on kind. It **must be removed**
  before any multi-consumer (goal 2) work, or the agent's default anti-collision name hashing won't
  protect against two consumers ordering the same name.
- The consumer `APIBinding` (`config/kcp/apibinding.yaml`) must `Accept` **all three** auto-added
  permissionClaims — `namespaces`, `secrets`, `events`. Missing any one → the binding never reaches
  `Bound` and the connection Secret never syncs back, with no loud error.
