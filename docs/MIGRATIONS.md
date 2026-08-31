# Helm chart migrations — data safety guide

This document covers operational safety when migrating an installed Helm release from one chart to another (e.g. `eks-1.0.1` → `client-1.0.3`), where **you must preserve the underlying PVC/PV data across the uninstall/install cycle.**

Read this **before** you plan any chart migration. Skipping the pre-flight verification can cost you PVCs even when you think you've protected them.

---

## The `resource-policy: keep` gotcha

> **Helm reads `helm.sh/resource-policy: keep` from the release's stored manifest (the `sh.helm.release.v1.<release>.v<N>` Secret), NOT from the live resource.**
>
> Running `kubectl annotate pvc X helm.sh/resource-policy=keep` on a live resource does **nothing** at `helm uninstall` time if the chart template didn't render that annotation. Helm will delete the PVC anyway.

This bit us on 2026-04-22, and a related variant bit us again on 2026-04-27. See [§ Case studies](#case-studies) at the end.

---

## Pre-flight verification (mandatory)

Before uninstalling the old release, check whether its stored manifest has the keep annotation on every resource you intend to preserve:

```bash
helm get manifest <release> -n <ns> | grep -B2 -A1 'resource-policy'
```

For every PVC / StorageClass / Namespace / Secret you must keep, verify the annotation is present in the output. If it's missing, **do not rely on live-annotating them** — pick one of the three options below.

---

## Mitigation options

There are two real options — **A** (preferred) and **C** (fallback). A third approach, stripping live Helm ownership labels (Option B), looks like it should work and reliably gets reached for first, but does not work; we document it below as a **cautionary tale** so operators don't burn a maintenance window discovering this on a production migration. We did, twice.

### Option A — `helm upgrade` to inject the annotation before uninstall (PREFERRED)

If the old chart supports passing extra annotations on PVCs via values (or you have a post-renderer), run an upgrade that adds `helm.sh/resource-policy: keep`. This updates the stored manifest. Subsequent `helm uninstall` honours it.

```bash
helm upgrade <release> <old-chart> -n <ns> \
  -f <current-values>.yaml \
  --set-json 'pvcAnnotations={"helm.sh/resource-policy":"keep"}'
# verify the annotation is now in the stored manifest:
helm get manifest <release> -n <ns> | grep 'resource-policy'
```

Only works if the chart exposes an annotations value. Many older charts don't.

### Option B — strip Helm ownership from the resource — DOES NOT WORK

You will be tempted to do this. Don't. It's the same class of mistake as `kubectl annotate ... helm.sh/resource-policy=keep` on a live PVC and expecting `helm uninstall` to honour it.

The intuition is: "if I remove `app.kubernetes.io/managed-by=Helm` and the `meta.helm.sh/release-name` annotation from the live resource, Helm will see it as un-owned and skip it on uninstall."

```bash
# PVC example — DOES NOT prevent uninstall from deleting the PVC
kubectl label pvc <pvc> -n <ns> app.kubernetes.io/managed-by-
kubectl annotate pvc <pvc> -n <ns> \
  meta.helm.sh/release-name- \
  meta.helm.sh/release-namespace-
```

**Why it fails**: same root cause as the keep-annotation gotcha at the top of this doc. `helm uninstall` iterates the resource list in the **stored release manifest** (the `sh.helm.release.v1.<release>.v<N>` Secret). For each entry it issues a DELETE — without re-checking the live resource's ownership labels first. Those labels matter for `helm install`'s adoption decision, not uninstall's deletion decision.

We learned this on 2026-04-27 by trying it on a StorageClass during the `tenant-d-prod` migration. The strip succeeded (live labels visibly empty), `helm uninstall` ran, and the StorageClass got deleted anyway. See [§ Case studies](#case-studies).

If you find yourself reaching for Option B, you actually want Option A or Option C.

### Option C — accept PVC deletion, rely on PV `reclaimPolicy: Retain` (FALLBACK)

If neither A nor B works and the underlying storage is `Retain`, the data survives PVC deletion. You'll need to rebuild the PVCs manually after uninstall:

```bash
# 1. Uninstall (PVCs deleted; PVs go to Released; underlying EFS/EBS intact)
helm uninstall <release> -n <ns>

# 2. Clear claimRef on each PV so it becomes Available
kubectl patch pv <pv-name> --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'

# 3. Re-create PVCs with spec.volumeName pointing at the retained PV
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <ns>
  annotations:
    helm.sh/resource-policy: keep
    meta.helm.sh/release-name: <new-release-name>
    meta.helm.sh/release-namespace: <ns>
  labels:
    app.kubernetes.io/managed-by: Helm
spec:
  storageClassName: <sc>
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: <size>   # must match PV capacity
  volumeName: <pv-name>
EOF
```

Only safe if the PV's `reclaimPolicy` is `Retain`. With `Delete` you lose data the moment the PV goes Released.

---

## Before uninstall: checklist

1. `helm get manifest <release> -n <ns> | grep resource-policy` — keep annotation present for every resource you must preserve?
2. `kubectl get pv $(kubectl get pvc -n <ns> -o jsonpath='{.items[*].spec.volumeName}') -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy` — all `Retain`?
3. Logical backup taken (for MySQL: `mysqldump | gzip > backup.sql.gz` **inside the pod**, then `kubectl cp` out — `kubectl exec > file` streams of >100 MB silently truncate)?
4. Snapshot of the underlying storage (EFS / EBS / NFS) taken?
5. Translated values file rendered (`helm template ... --dry-run=server`) and reviewed?
6. PVC name + storageClassName + size in the new chart match the existing PVCs?
7. **No active workloads in the namespace beyond the release itself.** `kubectl get jobs -n <ns>` for spawned training Jobs; `kubectl get pods -n <ns>` for anything else mounting the release's PVCs. Active pods hold PVCs in `Terminating` via the `kubernetes.io/pvc-protection` finalizer (their CSI mounts keep the PVC alive until the pod releases the volume), which can stall the migration for hours. Either wait for them to drain, or — if losing in-flight work is acceptable — `kubectl delete jobs -n <ns> --all` before `helm uninstall`. We missed this during the 2026-04-27 `tenant-d-prod` migration; 9 customer training Jobs were live and we had to delete them mid-migration.

Only proceed to `helm uninstall` when 1 **or** 2+3+4 is satisfied, and 5+6+7 are verified.

---

## Case studies

Two real migrations on the prod EKS cluster, both `eks-1.0.x` → `client-1.x`. Both ran the wrong protection trick first; both recovered via Option C. The pattern of failure has now bitten us twice on different live-resource-modification approaches; assume the next variant of "I'll just modify the live resource and helm will respect it" will also fail.

### 2026-04-22 — `tracebloc-templates` (`eks-1.0.1` → `client-1.0.3`)

- **Source:** release `tracebloc` on chart `eks-1.0.1`
- **Target:** chart `client-1.0.3`
- **What we did:** annotated PVCs + StorageClass with `helm.sh/resource-policy: keep` via `kubectl annotate`, then ran `helm uninstall`.
- **What happened:** `helm uninstall` deleted all 3 PVCs + the StorageClass despite the live annotations. The uninstall output **did not** include the usual "These resources were kept due to the resource policy" block.
- **Root cause:** the `eks-1.0.1` chart didn't template the keep annotation on PVCs. The stored release manifest had no annotation → Helm had no reason to skip them.
- **Recovery:** PVs had `reclaimPolicy: Retain` and EFS access points survive PV deletion, so no data was lost. We applied Option C above: recreated the StorageClass, cleared `claimRef` on the 3 PVs, re-created PVCs pointing at the retained PVs via `spec.volumeName`. `helm install <new>` then adopted the PVCs. MySQL came up with all 400K rows intact; shared and logs EFS directories intact.
- **Lesson:** never trust `kubectl annotate` alone to protect live Helm-owned resources. Always verify via `helm get manifest`.

### 2026-04-27 — `tenant-d-prod` (`eks-1.0.3` → `client-1.1.0`)

- **Source:** release `tenant-d-prod` on chart `eks-1.0.3` in `tracebloc-templates-prod`
- **Target:** chart `client-1.1.0`
- **What we did:** read this doc, identified that the StorageClass `client-storage-class` was Helm-owned (live: `app.kubernetes.io/managed-by=Helm`, `meta.helm.sh/release-name=tenant-d-prod`) with no `keep` annotation in the stored manifest, then tried Option B exactly as previously documented — stripped the live ownership label and the two release annotations.
- **What happened:** strip succeeded (verified live: `managed-by=` and `release-name=` both empty). `helm uninstall` ran. **The StorageClass was deleted anyway**, the PVCs went into `Terminating`, and we discovered mid-uninstall that 9 customer training Jobs were holding `client-pvc` and `client-logs-pvc` via `pvc-protection` finalizers.
- **Root cause:** `helm uninstall` iterates the stored release manifest's resource list and DELETEs each entry. It does not re-check the live resource's ownership before deleting. The label-strip is theatrical — it changes what `helm install` would adopt, not what `helm uninstall` deletes. Same root cause as the 2026-04-22 keep-annotation case, different mistake. **This is why Option B is now documented as "DOES NOT WORK" above.**
- **Compounding finding:** the pre-uninstall checklist had no item for active workloads in the namespace. The 9 training Jobs were spawned dynamically by `jobs-manager` and were not Helm-owned, so `helm uninstall` left them alone — but their pods kept the PVCs mounted, blocking deletion.
- **Recovery:** the user accepted losing the 9 in-flight training runs, so `kubectl delete jobs -n tracebloc-templates-prod --all` released the PVCs. From there, Option C as documented: cleared `claimRef` on the 3 PVs (Retain saved us again), re-created the StorageClass from the old values, pre-created PVCs with `volumeName` and the new release's Helm ownership stamp, then `helm install tenant-d-prod ./client-1.1.0`. mysql came up with 63 tables intact; the chart adopted the pre-created PVCs cleanly. Three independent backups (logical mysqldump, on-demand AWS Backup, daily automated AWS Backup) were untouched.
- **Lessons:** (1) Option B was a doc bug — fixed in this revision. (2) Pre-uninstall checklist now requires verifying no active workloads beyond the release itself. (3) When tempted to modify a live Helm-managed resource and expect uninstall to respect it, **assume it won't** until proven otherwise via `helm get manifest`.

---

## Verifying the new chart (`client-1.0.x` and later)

The new unified `client` chart DOES template `helm.sh/resource-policy: keep` on all three PVCs (`client-pvc`, `client-logs-pvc`, `mysql-pvc`). Confirmed on 2026-04-22 by uninstalling the `tb-client-test` release — Helm correctly reported the 3 PVCs + namespace as kept.

For migrations **away from** a release of this chart, Option A/B/C still apply if the destination chart uses different resource names. For migrations **between** versions of this chart, the keep annotation is already in the stored manifest, so no PVC is at risk — but a regular `helm upgrade` is **not unconditionally** safe: it aborts — leaving a partial, mixed state that reads as failure — when a non-Helm field manager owns a field the chart renders. See [§ `helm upgrade` aborts with a server-side apply conflict](#helm-upgrade-aborts-with-a-server-side-apply-conflict).

---

## `helm upgrade` aborts with a server-side apply conflict

A plain `helm upgrade` on a fleet **that has been running** can fail outright:

```
Error: UPGRADE FAILED: conflict occurred while applying object <ns>/<release>-jobs-manager
apps/v1, Kind=Deployment: Apply failed with 1 conflict: conflict with "kubectl-patch"
using apps/v1: .spec.template.spec.containers[name="api"].resources.limits.cpu
```

### Why it happens

**Helm 4 uses server-side apply by default.** Under server-side apply the API server tracks, per field, which *manager* last set it. When Helm re-applies the chart it refuses to take over a field another manager owns, and the upgrade errors out at that object — marking the release `failed`.

**It is not atomic.** Without `--atomic`, Helm applies objects in sequence and stops at the *first* conflict; everything it applied before that object **stays applied**. Verified: a plain `helm upgrade` that changed `mysql`'s memory limit *and* hit the `jobs-manager` conflict left mysql on the new value while reporting failure. So a conflict-aborted upgrade leaves the fleet in a **partial, mixed state that reads as a clean failure** — more dangerous than a no-op, and exactly the input `auto-upgrade`'s wedge detector then rolls back (`backend#2877`). Do not assume "it failed, so nothing changed"; check what landed.

The `kubectl-patch` in the message is the manager name the API server records for any `kubectl patch` command (verify: `kubectl set …` records `kubectl-set`, `kubectl annotate` records `kubectl-annotate`). So the field was taken over by an out-of-band `kubectl patch` at some point in the fleet's life — a manual resize, a migration step, a rehearsal. It is **not** a Helm or installer action, and **no runtime component of this chart patches that field**:

- The chart is the sole intended owner of `jobs-manager`'s `resources.limits.cpu` — the `1000m` ceiling is deliberate (issue #1144: keeps the api container Burstable while memory is pinned). Do **not** delete the declaration from the chart to dodge the conflict; that silently removes the CPU ceiling.
- `jobs-manager` reads `RESOURCE_REQUESTS` / `RESOURCE_LIMITS` / `RESOURCE_PROVENANCE` only to size the **training pods it spawns** — it never patches its own Deployment.
- `resource-monitor` (the node-agent DaemonSet) has RBAC on `pods` and `nodes` only.
- `image-refresh` uses `kubectl set image` (`kubectl-set`) and `kubectl annotate` (`kubectl-annotate`), never `kubectl patch`.

Confirm who owns the contested field on your fleet before you plan around it:

```bash
kubectl -n <ns> get deploy <release>-jobs-manager --show-managed-fields -o json \
  | jq '.metadata.managedFields[] | {manager, operation, time}'
```

### Recovery

Re-run the upgrade telling Helm to take the field back:

```bash
helm upgrade <release> tracebloc/client -n <ns> --reuse-values \
  --server-side=true --force-conflicts
```

Two things to know before you force:

1. **`--force-conflicts` re-takes *every* field the chart renders that a non-Helm manager owns — not only `limits.cpu`.** Helm prints the full conflict list on the failed attempt; read it first. On a long-running fleet the list can include `image-refresh`'s pinned digests (`kubectl set image`); forcing reverts them to the chart's rendered image, and `image-refresh` re-pins on its next tick. That is recoverable but is a real, if brief, image churn — don't force blind.

2. **`--server-side=true` is not optional, even though Helm 4 defaults to it.** After a rollback (including the automatic one the `auto-upgrade` CronJob performs when it reads a `pending-upgrade` release as a wedge — `backend#2877`), the release's stored apply method can revert to client-side. Then `--force-conflicts` **alone** fails with:

   ```
   Error: UPGRADE FAILED: invalid client update option(s): forceConflicts enabled when serverSideApply disabled
   ```

   Pass `--server-side=true` explicitly to override the stored method.

### The durable fix is to stop the out-of-band patch

Forcing the field back every upgrade is a workaround, not a resolution: whoever ran the `kubectl patch` re-creates the conflict the next time. Settle ownership instead — the chart owns `resources.limits.cpu`, so pin the value through chart values (`resources.jobsManager.limits.cpu`) and stop patching the live Deployment. If a real need arises for a component to own that field at runtime, the chart declaration is what has to go — but not before that owner exists.
