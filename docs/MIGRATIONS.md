# Helm chart migrations — data safety guide

This document covers operational safety when migrating an installed Helm release from one chart to another (e.g. `eks-1.0.1` → `client-1.0.3`), where **you must preserve the underlying PVC/PV data across the uninstall/install cycle.**

Read this **before** you plan any chart migration. Skipping the pre-flight verification can cost you PVCs even when you think you've protected them.

---

## The `resource-policy: keep` gotcha

> **Helm reads `helm.sh/resource-policy: keep` from the release's stored manifest (the `sh.helm.release.v1.<release>.v<N>` Secret), NOT from the live resource.**
>
> Running `kubectl annotate pvc X helm.sh/resource-policy=keep` on a live resource does **nothing** at `helm uninstall` time if the chart template didn't render that annotation. Helm will delete the PVC anyway.

This bit us on 2026-04-22. See [§ Case study](#case-study-tracebloc-templates-2026-04-22) at the end.

---

## Pre-flight verification (mandatory)

Before uninstalling the old release, check whether its stored manifest has the keep annotation on every resource you intend to preserve:

```bash
helm get manifest <release> -n <ns> | grep -B2 -A1 'resource-policy'
```

For every PVC / StorageClass / Namespace / Secret you must keep, verify the annotation is present in the output. If it's missing, **do not rely on live-annotating them** — pick one of the three options below.

---

## Mitigation options (in order of preference)

### Option A — `helm upgrade` to inject the annotation before uninstall

If the old chart supports passing extra annotations on PVCs via values (or you have a post-renderer), run an upgrade that adds `helm.sh/resource-policy: keep`. This updates the stored manifest. Subsequent `helm uninstall` honours it.

```bash
helm upgrade <release> <old-chart> -n <ns> \
  -f <current-values>.yaml \
  --set-json 'pvcAnnotations={"helm.sh/resource-policy":"keep"}'
# verify the annotation is now in the stored manifest:
helm get manifest <release> -n <ns> | grep 'resource-policy'
```

Only works if the chart exposes an annotations value. Many older charts don't.

### Option B — strip Helm ownership from the resource

If the old chart does not support templating the annotation, remove the Helm ownership labels/annotations from the resource before uninstalling. Helm won't recognise it as owned and will skip it.

```bash
# PVC example
kubectl label pvc <pvc> -n <ns> app.kubernetes.io/managed-by-
kubectl annotate pvc <pvc> -n <ns> \
  meta.helm.sh/release-name- \
  meta.helm.sh/release-namespace-
```

After uninstall, re-stamp the metadata before installing the new chart so the new release can adopt it:

```bash
kubectl label pvc <pvc> -n <ns> app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate pvc <pvc> -n <ns> \
  meta.helm.sh/release-name=<new-release-name> \
  meta.helm.sh/release-namespace=<ns> --overwrite
```

Trade-off: the resource is briefly orphaned between uninstall and re-stamp. Data is fine; only the ownership metadata is in flux.

### Option C — accept PVC deletion, rely on PV `reclaimPolicy: Retain`

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

Only proceed to `helm uninstall` when 1 **or** 2+3+4 is satisfied, and 5+6 are verified.

---

## Case study — `tracebloc-templates` migration, 2026-04-22

- **Source:** release `tracebloc` on chart `eks-1.0.1`
- **Target:** chart `client-1.0.3`
- **What we did:** annotated PVCs + StorageClass with `helm.sh/resource-policy: keep` via `kubectl annotate`, then ran `helm uninstall`.
- **What happened:** `helm uninstall` deleted all 3 PVCs + the StorageClass despite the live annotations. The uninstall output **did not** include the usual "These resources were kept due to the resource policy" block.
- **Root cause:** the `eks-1.0.1` chart didn't template the keep annotation on PVCs. The stored release manifest had no annotation → Helm had no reason to skip them.
- **Recovery:** PVs had `reclaimPolicy: Retain` and EFS access points survive PV deletion, so no data was lost. We applied Option C above: recreated the StorageClass, cleared `claimRef` on the 3 PVs, re-created PVCs pointing at the retained PVs via `spec.volumeName`. `helm install <new>` then adopted the PVCs. MySQL came up with all 400K rows intact; shared and logs EFS directories intact.
- **Lesson:** never trust `kubectl annotate` alone to protect live Helm-owned resources. Always verify via `helm get manifest`.

---

## Verifying the new chart (`client-1.0.x` and later)

The new unified `client` chart DOES template `helm.sh/resource-policy: keep` on all three PVCs (`client-pvc`, `client-logs-pvc`, `mysql-pvc`). Confirmed on 2026-04-22 by uninstalling the `tb-client-test` release — Helm correctly reported the 3 PVCs + namespace as kept.

For migrations **away from** a release of this chart, Option A/B/C still apply if the destination chart uses different resource names. For migrations **between** versions of this chart, the keep annotation is already in the stored manifest — a regular `helm upgrade` is safe.
