# Tenant migration tools — `eks-1.0.x` → `client-1.x`

Operational tooling captured during the 2026-04-27 / 2026-04-28 chart-family migrations on `eu-central-1/tracebloc-clients-prod`. Validated end-to-end on the `stg` and `tenant-d-prod` releases. Designed to be re-run for the remaining tenants (`tenant-b`, `tenant-c`, `tenant-a`) and any future tenant on the same legacy chart.

Read [`../MIGRATIONS.md`](../MIGRATIONS.md) first for the *why* — this directory is the *how*.

## Contents

| File | Purpose |
|---|---|
| `tenant-config.example.env` | Per-tenant secrets + PV mappings template. Copy, fill in real values, keep local. **Never commit a populated copy.** |
| `generate.sh` | Reads `tenant-config.env` (or whatever you point `TENANT_CONFIG` at) and emits `values.yaml`, `pvcs.yaml`, `storageclass.yaml` for every tenant in the file, into `/tmp/tracebloc-migration-<tenant>/`. |
| `migrate-tenant.sh phase1\|phase2 <tenant>` | Parameterised runbook. Phase 1 is non-destructive (mysqldump, AWS Backup, render). Phase 2 is destructive (`helm uninstall` → claimRef clear → SC re-create → PVC pre-create → `helm install` → verify). |
| `regcred-existing-secret.md` | Operational runbook for moving a fleet's registry credential out of its Helm release values (backend#2571). Drives the two `regcred-*` tools below. Records the three things measured on a k3d rehearsal: `helm upgrade` cannot tell you the migration is half-done, the chart's own Secret is **deleted** rather than orphaned, and `<release>-regcred` is a name collision on our releases. |
| `regcred-preflight.sh <rel> <ns> <chart> <values.yaml>` | Gate for the `dockerRegistry.create` -> `existingSecret` migration (backend#2571). Renders the chart with the values you are about to apply and refuses unless the target pull Secret exists, with the right type, in **every** namespace the render references it from. `helm upgrade` does not check this: a copy made into only one of the two namespaces reports `STATUS: deployed` and leaves those workloads unable to pull. Exit 0 safe, 1 would break, 2 cannot tell. |
| `regcred-copy.py <new-name>` | Copies a Helm-managed pull Secret under an operator-owned name, stripping every trace of Helm ownership so Helm cannot adopt and later delete it. The credential is never decoded, printed or retyped. The new name must NOT be `<release>-regcred` — that is the chart's own name and applying over it rewrites the live Secret in place. |

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
./migrate-tenant.sh phase1 tenant-a
# … review …
./migrate-tenant.sh phase2 tenant-a
# … 24h soak watching `kubectl describe pod mysql-client -n tenant-a` …

./migrate-tenant.sh phase1 tenant-c
./migrate-tenant.sh phase2 tenant-c
# … 24h soak …

./migrate-tenant.sh phase1 tenant-b
./migrate-tenant.sh phase2 tenant-b
```

The scripts always pass `--context` explicitly on every `kubectl` / `helm` call to avoid the context-drift bug that hit us mid-migration on prod.

## Order

For the current pending set:

1. **`tenant-a` first** — quietest tenant (no kill-loop activity). A buggy migration here is least disruptive. Confirms the protocol is mechanical.
2. **`tenant-c`** — kill-loop active, no in-flight jobs as of last survey.
3. **`tenant-b`** — same as tenant-c, plus older `eks-1.0.2` chart (vs 1.0.3). Save it for last in case there's a 1.0.2 quirk.

24h soak between each. Post-migration watch:

```bash
kubectl --context "$CTX" describe pod mysql-client -n <ns> | grep -A2 'Last State'
# expected: "Last State: <none>" (no Reason: Error / Exit 1 reappearance)
```

## Skipped chart features and why

The generated `values.yaml` ships with several `*.create: false` toggles that are intentional:

| Field | Why |
|---|---|
| `resourceMonitor: false` | Conservative default. The release-scoped resource-monitor names landed in `client-1.2.0` — on that version or later you can flip this to `true` and each tenant gets its own DaemonSet + per-`CLIENT_ID` metric stream without colliding with sibling releases on the same cluster. Older charts (<1.2.0) collide on the literal `tracebloc-resource-monitor` ServiceAccount when a second release tries to install; if you happen to be installing one of those, leave this `false` and stg's DaemonSet covers metrics on every node. |
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
