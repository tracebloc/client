# Tenant migration tools — `eks-1.0.x` → `client-1.x`

Operational tooling captured during the 2026-04-27 / 2026-04-28 chart-family migrations on `eu-central-1/tracebloc-clients-prod`. Validated end-to-end on the `stg` and `hasan-prod` releases. Designed to be re-run for the remaining tenants (`bmw`, `cisco`, `charite`) and any future tenant on the same legacy chart.

Read [`../MIGRATIONS.md`](../MIGRATIONS.md) first for the *why* — this directory is the *how*.

## Contents

| File | Purpose |
|---|---|
| `tenant-config.example.env` | Per-tenant secrets + PV mappings template. Copy, fill in real values, keep local. **Never commit a populated copy.** |
| `generate.sh` | Reads `tenant-config.env` (or whatever you point `TENANT_CONFIG` at) and emits `values.yaml`, `pvcs.yaml`, `storageclass.yaml` for every tenant in the file, into `/tmp/tracebloc-migration-<tenant>/`. |
| `migrate-tenant.sh phase1\|phase2 <tenant>` | Parameterised runbook. Phase 1 is non-destructive (mysqldump, AWS Backup, render). Phase 2 is destructive (`helm uninstall` → claimRef clear → SC re-create → PVC pre-create → `helm install` → verify). |

## Workflow

```bash
cd docs/migration-tools/

# 1. Bootstrap the secrets file (kept local, never committed).
cp tenant-config.example.env tenant-config.env
# edit tenant-config.env: fill in CLIENT_ID, CLIENT_PASSWORD, DOCKER_PASSWORD,
# and verify the per-tenant PV IDs match `kubectl get pv ...` on the cluster.

# 2. Generate per-tenant artifacts (into /tmp/tracebloc-migration-<tenant>/).
./generate.sh

# 3. For each tenant — Phase 1 first. Eyeball outputs. Confirm AWS Backup
#    job COMPLETED, dump file size > 0 + gzip OK, helm template clean.
./migrate-tenant.sh phase1 charite
# … review …
./migrate-tenant.sh phase2 charite
# … 24h soak watching `kubectl describe pod mysql-client -n charite` …

./migrate-tenant.sh phase1 cisco
./migrate-tenant.sh phase2 cisco
# … 24h soak …

./migrate-tenant.sh phase1 bmw
./migrate-tenant.sh phase2 bmw
```

The scripts always pass `--context` explicitly on every `kubectl` / `helm` call to avoid the context-drift bug that hit us mid-migration on prod.

## Order

For the current pending set:

1. **`charite` first** — quietest tenant (no kill-loop activity). A buggy migration here is least disruptive. Confirms the protocol is mechanical.
2. **`cisco`** — kill-loop active, no in-flight jobs as of last survey.
3. **`bmw`** — same as cisco, plus older `eks-1.0.2` chart (vs 1.0.3). Save it for last in case there's a 1.0.2 quirk.

24h soak between each. Post-migration watch:

```bash
kubectl --context "$CTX" describe pod mysql-client -n <ns> | grep -A2 'Last State'
# expected: "Last State: <none>" (no Reason: Error / Exit 1 reappearance)
```

## Skipped chart features and why

The generated `values.yaml` ships with several `*.create: false` toggles that are intentional:

| Field | Why |
|---|---|
| `resourceMonitor: false` | Until the chart fix that release-scopes `tracebloc-resource-monitor` SA + DaemonSet (`client-1.2.0`) is published. The shared name collides between releases. Stg's DaemonSet runs on every node and collects metrics; per-tenant `CLIENT_ID` metric streams come back when the tenant is upgraded to `client-1.2.0+` with `resourceMonitor: true`. |
| `priorityClass.create: false` | `tracebloc-data-plane` was created cluster-scoped by the stg migration. Subsequent installs reference it. |
| `nodeAgents.namespace.create: false` | `tracebloc-node-agents` exists cluster-wide from stg. |
| `namespace.create: false` | Each tenant namespace pre-exists from the legacy release. |
| `storageClass.create: false` | Each tenant has a tenant-specific SC (`<tenant>-awsefs`); we re-create it explicitly via `storageclass.yaml` in Phase 2 because `helm uninstall` deletes the Helm-templated one. |
| `networkPolicy.training.enabled: false` | Preserves legacy behaviour. EKS without an enforcing CNI add-on means turning it on is silently no-op anyway. |

## Recovery layers per migration

After Phase 1 each tenant has three independent recovery paths:

1. **Logical mysqldump** at `/tmp/tracebloc-migration-<tenant>/<tenant>-backup.sql.gz`. Fastest to restore for mysql data alone.
2. **On-demand AWS Backup recovery point** of EFS `fs-06b3faf51675ff9f9`. Captures all access points (mysql, shared, logs).
3. **PV `reclaimPolicy: Retain`**. Underlying EFS access points survive PV deletion; re-bind by `volumeName` is the documented recovery path (Option C in `MIGRATIONS.md`).

## Re-running the survey

Tenant data captured by hand on 2026-04-28. If a tenant's PVs or release name change, re-run the survey commands at the top of `tenant-config.example.env` and update `tenant-config.env`. The PVs are `Retain`, so PV IDs are stable across the legacy chart's lifetime.

## After all migrations are done

This directory becomes historical. The `migrate-tenant.sh` script is specific to the `eks-1.0.x` → `client-1.x` family transition; once every tenant is on `client-1.x` the runbook isn't needed for routine `client-1.x` → `client-1.y` upgrades (those follow `helm upgrade` because the chart already templates `helm.sh/resource-policy: keep` on PVCs). Keep this directory for historical reference and the `MIGRATIONS.md` case study, or delete it once the institutional memory has faded sufficiently to make resurrecting it harder than re-deriving.
