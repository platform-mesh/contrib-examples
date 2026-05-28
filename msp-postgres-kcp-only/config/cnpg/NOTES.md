# CNPG Connection-Secret Semantics

## What CNPG generates for `pg-demo`

When `bootstrap.initdb` sets `owner: app`, CloudNativePG automatically creates an application
user Secret named `<cluster>-app`. The `-app` suffix is a **hardcoded constant** in CNPG
(`ApplicationUserSecretSuffix = "-app"`) — it is NOT derived from the `owner` field. Changing
`owner` to a different value changes the Postgres role name but does NOT change the Secret name:

| Resource | Kind | Notes |
|---|---|---|
| `pg-demo-app` | `Secret` (type `kubernetes.io/basic-auth`) | Connection credentials for the `app` user |
| `pg-demo-rw`  | `Service` (ClusterIP, port 5432) | Routes to the primary (read-write) |
| `pg-demo-ro`  | `Service` (ClusterIP, port 5432) | Routes to replicas (read-only) |
| `pg-demo-r`   | `Service` (ClusterIP, port 5432) | Routes to any replica |

> No `pg-demo-superuser` Secret is generated because `enableSuperuserAccess` is omitted
> (defaults to `false` in CNPG ≥ 1.20).

## Secret keys — `pg-demo-app`

| Key | Example value | Description |
|---|---|---|
| `username` | `app` | Postgres role name |
| `password` | `<generated>` | Randomly generated password |
| `dbname` | `appdb` | Database name from `initdb.database` |
| `host` | `pg-demo-rw.default.svc` | FQDN of the read-write Service |
| `port` | `5432` | Service port |
| `uri` | `postgresql://app:<pass>@pg-demo-rw.default.svc:5432/appdb` | Full connection URI |
| `pgpass` | `pg-demo-rw.default.svc:5432:appdb:app:<pass>` | pgpass-file format |

## Sync-back implications

`syncagent-expert` must configure a `related` resource rule to sync the `pg-demo-app` Secret
back from kind → kcp consumer workspace alongside the `Cluster` status.  The Secret name is **exactly** `pg-demo-app` (cluster name `pg-demo` + hardcoded suffix `-app`).

## Live connectivity (for `test-verifier`)

The read-write endpoint inside kind is `pg-demo-rw.default.svc:5432`.  Because the cluster has
no `hostPath` DNS on the host, use a one-shot Job in kind to run the live `SELECT`:

```yaml
# example — run with kubectl --kubeconfig "$KIND_KUBECONFIG" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-smoke-test
  namespace: default
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: ghcr.io/cloudnative-pg/postgresql:17
        command:
        - sh
        - -c
        - |
          psql "$(cat /secret/uri)" -c "SELECT version();"
        volumeMounts:
        - name: secret
          mountPath: /secret
      volumes:
      - name: secret
        secret:
          secretName: pg-demo-app
          items:
          - key: uri
            path: uri
```

Alternatively, use `postgres:17` with individual env vars (`PGHOST`, `PGUSER`, `PGPASSWORD`,
`PGDATABASE`) sourced from the same Secret.
