# msp-cert-manager

Turn TLS certificate issuance into an **orderable service** on a kcp control plane — using
[cert-manager](https://cert-manager.io), [kro](https://kro.run), and the
[api-syncagent](https://github.com/kcp-dev/api-syncagent) to bridge a consumer's kcp workspace
and the cluster where cert-manager actually runs.

No custom operator is written. The entire provider is declarative YAML.

## What it shows

| Layer | What happens |
|-------|-------------|
| **Consumer** | Orders a `certmanager.ca/v1alpha1/Certificate{fqdn}` in their kcp workspace |
| **api-syncagent** | Syncs the order down to a kind cluster |
| **kro** | Translates `certmanager.ca/Certificate` → `cert-manager.io/Certificate` via a `ResourceGraphDefinition` |
| **cert-manager** | Issues the certificate; generates a TLS `Secret` |
| **api-syncagent** | Syncs the TLS `Secret` back up to the consumer workspace |

> **No resource-broker.** The consumer binds the provider's `api-syncagent` APIExport directly.
> This is the simplest possible wiring for a single cert-manager MSP.

See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid flow and design notes.

## Pinned stack

| Component | Version |
|-----------|---------|
| kcp | v0.31.2 |
| api-syncagent | v0.6.0 |
| cert-manager | v1.17.2 |
| kro | v0.3.0 |

Do not bump versions independently — this stack is validated as a unit.

## Prerequisites

- `docker` (Docker Desktop recommended — provides `host.docker.internal` for kcp↔kind connectivity)
- `kind`
- `kubectl`
- `helm`
- `yq` (mikefarah/yq v4+)
- `curl`
- `task` ([Taskfile](https://taskfile.dev))
- `openssl` (optional — used by `task verify` to inspect the issued certificate)

Run `task tools:check` to verify all required tools are present.

## Quick start

```sh
# 1. Stand up the full stack (kcp + kind + cert-manager + kro + api-syncagent)
task up

# 2. Order a TLS certificate as a consumer
task order

# 3. Verify the end-to-end loop
task verify

# 4. Tear everything down
task down
```

All commands run from the `msp-cert-manager/` directory.

## Per-target reference

| Target | What it does | Script |
|--------|-------------|--------|
| `task tools:check` | Verify required CLIs | `hack/tools-check.sh` |
| `task tools:kcp` | Download & pin kcp v0.31.2 into `bin/` | `hack/tools-kcp.sh` |
| `task kcp:start` | Start kcp locally | `hack/kcp-start.sh` |
| `task kcp:stop` | Stop kcp | `hack/kcp-stop.sh` |
| `task kcp:workspaces` | Create provider + consumer workspaces, seed empty APIExport | `hack/kcp-workspaces.sh` |
| `task kind:up` | Create kind cluster `msp-cert-manager` | `hack/kind-up.sh` |
| `task kind:down` | Delete kind cluster | `hack/kind-down.sh` |
| `task certmanager:install` | Install cert-manager + ClusterIssuer + kro RGD into kind | `hack/certmanager-install.sh` |
| `task kro:install` | Install kro into kind | `hack/kro-install.sh` |
| `task syncagent:kubeconfig` | Build provider-workspace kubeconfig, store as Secret in kind | `hack/syncagent-kubeconfig.sh` |
| `task syncagent:install` | Helm-install api-syncagent into kind | `hack/syncagent-install.sh` |
| `task syncagent:publish` | Apply RBAC + PublishedResource on kind | `hack/syncagent-publish.sh` |
| `task provider:bind` | Bind the consumer workspace to the provider APIExport | `hack/provider-bind.sh` |
| `task order` | Order Certificate `my-cert` in the consumer workspace | `hack/order.sh` |
| `task verify` | End-to-end proof | `test/e2e.sh` |
| `task status` | Show live state (non-destructive) | inline |
| `task up` | Full `task up` pipeline (integration runner only) | all of the above |
| `task down` | Tear everything down | `hack/kcp-stop.sh` + `hack/kind-down.sh` |

## Env vars contract

All configuration is exported by `Taskfile.yml` as env vars. Scripts read these — never hardcode.

| Var | Default | Notes |
|-----|---------|-------|
| `KCP_VERSION` | `v0.31.2` | kcp server + kubectl-ws/kubectl-kcp plugins |
| `SYNCAGENT_VERSION` | `0.6.0` | api-syncagent Helm chart version |
| `CERTMANAGER_VERSION` | `1.17.2` | cert-manager manifest version |
| `KRO_VERSION` | `0.3.0` | kro Helm chart version |
| `KIND_CLUSTER` | `msp-cert-manager` | kind cluster name |
| `PROVIDER_WS` | `root:msp:cert-manager-provider` | provider kcp workspace |
| `CONSUMER_WS` | `root:msp:customer-a` | consumer kcp workspace |
| `ORDER_NAME` | `my-cert` | Certificate CR name ordered by the consumer |
| `ORDER_NS` | `default` | namespace for the ordered Certificate |
| `KCP_EXTERNAL_HOST` | `host.docker.internal` | host reachable from inside kind pods |
| `KCP_KUBECONFIG` | `.kcp/admin.kubeconfig` | kcp admin kubeconfig (host-side) |
| `KIND_KUBECONFIG` | `.kube/kind.kubeconfig` | kind cluster kubeconfig |

## Validating edits without standing up the stack

```sh
# Lint shell scripts
shellcheck hack/*.sh test/e2e.sh

# Lint YAML manifests
yamllint config/

# Dry-run built-in kinds
kubectl create --dry-run=client -f config/kcp/apiexport.yaml
kubectl create --dry-run=client -f config/kcp/apibinding.yaml

# Render the syncagent Helm chart
helm template kcp-api-syncagent kcp/api-syncagent \
  --version 0.6.0 \
  --values config/syncagent/values.yaml
```

## Ordering a certificate manually

After `task up`:

```sh
# Switch into the consumer workspace
KUBECONFIG=.kcp/admin.kubeconfig kubectl ws root:msp:customer-a

# Order a certificate
kubectl --kubeconfig .kcp/admin.kubeconfig apply -f- <<EOF
apiVersion: certmanager.ca/v1alpha1
kind: Certificate
metadata:
  name: my-cert
  namespace: default
spec:
  fqdn: my-app.example.com
EOF

# Watch for the TLS Secret to appear in the consumer workspace
kubectl --kubeconfig .kcp/admin.kubeconfig \
  get secret my-cert -n default -w

# Inspect the issued certificate
kubectl --kubeconfig .kcp/admin.kubeconfig \
  get secret my-cert -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -text
```

## Troubleshooting

**api-syncagent does not sync the order to kind:**
```sh
kubectl --kubeconfig .kube/kind.kubeconfig \
  -n kcp-system logs -l app.kubernetes.io/name=kcp-api-syncagent --tail=100
```
The most common cause is `host.docker.internal` not resolving inside the kind pod. Enable the
`hostAliases` fallback in `config/syncagent/values.yaml` (see comment at the bottom of that file).

**kro RGD is not Ready:**
```sh
kubectl --kubeconfig .kube/kind.kubeconfig \
  get resourcegraphdefinition.kro.run/certificates.certmanager.ca -o yaml
kubectl --kubeconfig .kube/kind.kubeconfig \
  -n kro-system logs -l app.kubernetes.io/name=kro --tail=50
```

**cert-manager does not issue the certificate:**
```sh
kubectl --kubeconfig .kube/kind.kubeconfig \
  -n default get certificate.cert-manager.io my-cert -o yaml
kubectl --kubeconfig .kube/kind.kubeconfig \
  -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=50
```

**TLS Secret does not sync back:**
Check that the PublishedResource `related` block is populated and the agent has RBAC access to
`secrets` (`config/syncagent/rbac.yaml`). Look at agent logs for "related" sync errors.

**APIBinding does not reach Bound:**
The consumer binding needs all three permissionClaims (namespaces, secrets, events) Accepted.
If one is missing, the binding stays `Initializing` indefinitely with no loud error.
