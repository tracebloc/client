# Migration Guide: Per-Platform Charts → Unified `tracebloc` Chart

This guide explains how to migrate from the legacy per-platform charts (`aks/`, `bm/`, `eks/`, `oc/`) to the unified `client/` chart.

## Upgrading to 1.9.49 — `RESOURCE_PROVENANCE`: who chose the training envelope

**Nothing to do.** This adds a bookkeeping key. It never changes the training
envelope, and an upgrade cannot move any edge's training size.

### What it is

`env.RESOURCE_PROVENANCE` records **who** chose `RESOURCE_REQUESTS` /
`RESOURCE_LIMITS`:

| Value | Meaning |
|---|---|
| `installer` | sized to this machine at install time |
| `user` | an explicit `tracebloc resources set`, or a `TRACEBLOC_TRAINING_RESOURCES` install-time override |
| `unknown` | carried forward from before this key existed — genuinely unattributable |

It renders only when the envelope itself is set, and defaults to `unknown` on
any release that predates it.

### Why it has to exist

`RESOURCE_*` has **no unset state** once Helm has seen it. The fleet auto-upgrade
CronJob runs `helm upgrade --reset-then-reuse-values`, which re-applies the
release's *user-supplied* values forever, and the installer reconcile path does
the same. So a value written once at install time is re-applied indefinitely.

That means an installer-written envelope and a deliberate human choice are
**indistinguishable** once the value differs from the historic
`cpu=2,memory=8Gi` literal — the installer carries any differing value forward
precisely because it cannot tell them apart. Without a marker, any future
automatic-sizing work would have to either strand every already-pinned edge or
silently overrule operators who had deliberately set a size. Neither is
acceptable, so the marker records the difference from now on (backend#2220).

**`unknown` must be treated as `user`.** It means we do not know, and guessing
`installer` would risk overruling a human. Existing edges will therefore report
`unknown` and keep their current size until someone opts in explicitly.

### If you want an edge to size itself from the node again

Clearing the envelope is an **explicit, deliberate** act — a chart change cannot
do it for you, because `--reset-then-reuse-values` re-applies the stored
user-supplied value on every upgrade. Setting the keys to `null` removes them
(Helm deletes null-valued keys during value coalescing), which drops all three
env vars and returns `jobs-manager` to its built-in `cpu=1,memory=2Gi` literal
(the contract floor since backend#2254; it was `cpu=2,memory=8Gi`)
— and, if `env.DERIVE_JOB_ENVELOPE` is also set, unblocks the node-allocatable
derivation (read the caveat below before you do that):

```bash
helm upgrade "$NAMESPACE" tracebloc/tracebloc -n "$NAMESPACE" \
  --reset-then-reuse-values \
  --set env.RESOURCE_LIMITS=null \
  --set env.RESOURCE_REQUESTS=null \
  --set env.RESOURCE_PROVENANCE=null
```

Verify the three vars are gone before relying on it:

```bash
kubectl -n "$NAMESPACE" get deploy "$NAMESPACE-jobs-manager" -o yaml | grep RESOURCE_
```

> **Read this before you run it.** Node-derived sizing is currently gated OFF by
> default (`DERIVE_JOB_ENVELOPE`, backend#2167): an envelope sized to ~75% of a
> node fits only **one** training job per node, so a second concurrent
> experiment cannot schedule. With the gate off, clearing the keys returns the
> edge to the fixed `cpu=1,memory=2Gi` literal — the contract floor since
> backend#2254, which fits the smallest host we support. (Before #2254 the
> fallback was `cpu=2,memory=8Gi`, which on a machine with less than ~8 GiB
> allocatable could not schedule at all, so clearing the keys on a small machine
> was unsafe; the floor removes that hazard.) To opt in to node sizing
> deliberately, clear the pair **and** set the gate in
> the same upgrade — `--set-string env.DERIVE_JOB_ENVELOPE=true`, with
> `--set-string`, because every key under `env` is typed `string` and a bare
> `--set ...=true` is rejected as a boolean. The key is documented in
> `client/values.yaml` (backend#2250).

## Upgrading to 1.9.6 — the prod ingestor pin moved into chart defaults; `values-prod.yaml` removed

The digest that pins the spawned ingestion image on prod now lives in the
chart's **default** `client/values.yaml` as `images.ingestor.prodDigest`, gated
to prod. The `client/values-prod.yaml` install-time overlay has been **deleted**.

**Why:** an install-time `-f` overlay could never deliver the pin.

- The installer only ever passes its own generated values file, so a standard
  prod install never applied the overlay at all — prod floated on the tag
  exactly like dev and staging.
- Even where an operator layered it by hand, it could never be *updated*. The
  fleet auto-upgrade CronJob runs `helm upgrade --reset-then-reuse-values` with
  no `-f` and no `--set`: that resets to the **new chart's `values.yaml`
  defaults**, then re-applies the release's stored **user-supplied** values. An
  overlay value is user-supplied, so it was replayed verbatim forever — and
  because Helm only auto-reads `values.yaml` from a chart, the overlay shipped
  inside the new chart archive was never read. The edge stayed frozen on its
  install-day digest while the chart version advanced.

Chart **defaults** propagate through that upgrade; user-supplied values freeze.
So the pin has to be a default, which is how the egress-proxy squid image has
always been pinned. Removing the overlay rather than keeping it as a shim is
deliberate: passing `-f values-prod.yaml` would re-create the frozen-value bug.

**What you need to do: nothing for most clusters.**

| Edge | `env.CLIENT_ENV` | Ingestor image |
|---|---|---|
| Prod (installer writes no `CLIENT_ENV`) | unset → resolves `prod` | Pinned to `images.ingestor.prodDigest`, `imagePullPolicy: IfNotPresent` |
| Dev / staging | `dev` / `stg` | Floating `images.ingestor.tag`, `imagePullPolicy: Always` (unchanged) |

The pin arrives on the next hands-off auto-upgrade, and each subsequent
republished pin follows the same way.

**If you hand-layered the old overlay, clear the stored value.** A manually
applied `-f client/values-prod.yaml` stored `images.ingestor.digest` as a
user-supplied value, and that key still takes precedence over `prodDigest` — so
such an edge would stay frozen on its install-day digest. Clear it once:

```bash
helm upgrade <release> tracebloc/client -n <namespace> \
  --reset-then-reuse-values --set images.ingestor.digest=""
```

Confirm the edge now tracks the chart pin:

```bash
kubectl get deploy -n <namespace> <release>-jobs-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="INGESTOR_IMAGE_DIGEST")].value}{"\n"}'
```

**Canary edges.** To float one prod edge on the tag while the rest of the fleet
stays pinned — e.g. to validate a new ingestor release in place — set
`images.ingestor.prodPin=false` on that edge. It is user-supplied, so the
opt-out persists across auto-upgrades until you change it back. To pin an edge
to a *specific* different digest instead, set `images.ingestor.digest`; that
wins in any environment.

## Upgrading to 1.5.1 — single-node gating of the GPU→CPU pending fallback

[client-runtime#92](https://github.com/tracebloc/client-runtime/issues/92) /
[#222](https://github.com/tracebloc/client/issues/222): jobs-manager's
GPU→CPU fallback (a GPU pod stuck `Pending` past the scheduling-overdue
interval is stopped and respun as a CPU job) is now gated on a new
`env.SINGLE_NODE` flag.

**Why:** on a multi-node / elastic cluster (EKS cluster-autoscaler / Karpenter,
AKS) a `Pending` GPU pod usually just means a GPU node is still autoscaling in
(3–10 min). Downgrading to CPU after ~180s is premature — it silently moves a
GPU experiment onto CPU and drives the stop→respin token churn behind the
[client-runtime#80](https://github.com/tracebloc/client-runtime/issues/80) 401
race. On a fixed single-node cluster (installer-provisioned k3d) GPU presence is
known at install time and no node will autoscale in, so the fallback is correct.

**What you need to do: nothing for most clusters.** `SINGLE_NODE` defaults to
`hostPath.enabled`, so the behavior tracks your existing topology across the
hands-off auto-upgrade:

| Deployment | `hostPath.enabled` | `SINGLE_NODE` default | Behavior |
|---|---|---|---|
| Installer k3d / bare-metal single-host | `true` | `"true"` | GPU→CPU fallback **on** (unchanged) |
| EKS / AKS / OpenShift (dynamic PVC) | `false` | `"false"` | Pending GPU pods left for the autoscaler |

- **EKS/AKS/OpenShift** automatically stop the premature downgrade on the next
  auto-upgrade — no value change needed.
- **The installer** now writes `env.SINGLE_NODE: "true"` explicitly for new k3d
  installs, so they don't depend on the heuristic.
- **A fixed multi-node bare-metal cluster** (e.g. an NFS-backed cluster with
  `hostPath.enabled: false`) that *wants* the hard CPU/GPU fallback must set it
  explicitly: `env.SINGLE_NODE: "true"`. Must be a quoted string.

`SINGLE_NODE` requires the matching jobs-manager image (it ships in the same
release train). During the brief window where image-refresh rolls the new image
before this chart upgrade injects the var, an absent `SINGLE_NODE` is treated as
single-node (fallback on), so a single-node cluster is never regressed mid-rollout.

## Upgrading to 1.3.4 — parent chart owns the shared ingestor ServiceAccount

[#129](https://github.com/tracebloc/client/issues/129): the ingestor
ServiceAccount has moved from the `tracebloc/ingestor` subchart into this
parent chart. Background: the SA is shared by every ingestor subchart
release in a namespace, but per-release Helm ownership meant two concurrent
`helm install tracebloc/ingestor` calls collided with "cannot import into
current release", and uninstalling the first release ripped the SA out
from under all the others. With the SA in the parent chart, every
ingestor release in the namespace shares it cleanly and `helm uninstall`
of any individual ingestor release leaves it alone.

> **The matching ingestor subchart change** ships as
> `tracebloc/ingestor` **0.2.0** — `serviceAccount.create` default
> flipped from `true` to `false`. Upgrade the subchart releases in
> lockstep with the parent so they stop trying to own the SA.

### When you need to adopt an existing SA

If you already have a `tracebloc/ingestor` 0.1.0 release installed in the
same namespace as this `tracebloc/client` release, `kubectl get sa
ingestor -n <ns> -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}'`
returns that subchart release's name. Plain `helm upgrade tracebloc/client`
to 1.3.4 will fail with `Unable to continue with update: ServiceAccount
"ingestor" ... exists and cannot be imported into the current release`.

Transfer Helm ownership before upgrading:

```bash
# 1. Identify the values you need.
NAMESPACE=<your-tracebloc-namespace>
CLIENT_RELEASE=<your-client-release-name>          # e.g. "tracebloc"
SA_NAME=ingestor                                    # or ingestionAuthz.serviceAccountName if overridden

# 2. Re-annotate the SA so Helm sees the parent client release as its owner.
kubectl annotate sa "$SA_NAME" -n "$NAMESPACE" \
  meta.helm.sh/release-name="$CLIENT_RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

kubectl label sa "$SA_NAME" -n "$NAMESPACE" \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

# 3. Now run the upgrade — Helm adopts the SA on next reconcile.
helm upgrade "$CLIENT_RELEASE" tracebloc/client \
  -n "$NAMESPACE" --version 1.3.4 --reset-then-reuse-values

# 4. Upgrade each ingestor subchart release to 0.2.0 so it stops trying
#    to create the SA itself. The flipped default does this for you, but
#    use --reset-then-reuse-values so pre-0.2.0 stored values don't
#    re-apply serviceAccount.create=true.
helm upgrade <ingestor-release> tracebloc/ingestor \
  -n "$NAMESPACE" --version 0.2.0 --reset-then-reuse-values
```

If no ingestor 0.1.0 release exists in the namespace yet, you don't have
to do anything — the parent chart creates the SA on first install of
1.3.4 and subsequent ingestor 0.2.0 releases consume it.

### `--reuse-values` upgrade path

Operators using plain `--reuse-values` (or the auto-upgrade cronjob
prior to 1.3.0, which used that flag) won't get the new
`ingestionAuthz.serviceAccountName` default. The chart's template
defaults the value to `"ingestor"` when absent, so the SA is created
with the expected name and existing `allowed` entries keep matching.
No template-level breakage; this is the same nil-guard pattern as
[#124](https://github.com/tracebloc/client/pull/124).

## Upgrading to 1.3.0 — self-upgrade CronJob lands on by default

Releases of 1.3.0+ install a `<release>-auto-upgrade` CronJob that polls
`https://tracebloc.github.io/client` and runs
`helm upgrade --reset-then-reuse-values` when a newer chart version is
published. This closes [tracebloc/client#69](https://github.com/tracebloc/client/issues/69) —
older deployed clients stop drifting from the latest secure / stable release.

The default cadence is **hourly at :23 UTC** as of 1.3.2 (was daily at 02:23
UTC in 1.3.0 / 1.3.1). The off-hour minute spreads load across the
`tracebloc.github.io/client` GitHub Pages origin. Operators who want a
different schedule can override `autoUpgrade.schedule`.

> **Verified end-to-end on `tb-client-dev-templates` during the 1.3.1 release**:
> a `tracebloc` release at 1.3.0 self-upgraded to 1.3.1 within a single
> CronJob tick after publish, with no operator intervention.

> **Operator note for the 1.x → 1.3.0 jump.** Use `--reset-then-reuse-values`
> on the *manual* upgrade command too, not plain `--reuse-values`. The new
> `autoUpgrade` block was added in 1.3.0; with `--reuse-values` Helm reuses
> the last release's *computed* values, which don't contain `autoUpgrade`,
> and the new templates fail with `nil pointer evaluating interface {}.enabled`.
> Once you're on 1.3.0+ the CronJob handles future bumps with the correct
> flag itself.
>
> ```bash
> helm upgrade <release> tracebloc/client \
>   -n <namespace> --version 1.3.0 \
>   --reset-then-reuse-values
> ```

The upgrader's ServiceAccount is bound to the built-in `cluster-admin`
ClusterRole because the chart already templates cluster-scoped resources
(`PriorityClass`, `StorageClass`, `ClusterRole`/`Binding`, optionally
`Namespace`); a curated narrower role would silently break the day a future
chart version adds a new resource kind.

To opt out and keep the manual approval gate you had on 1.2.x:

```yaml
# values-overrides.yaml
autoUpgrade:
  enabled: false
```

Or for a one-shot pause without removing the resources, set
`autoUpgrade.suspend: true`.

## What Changed

| Legacy | Unified |
|--------|---------|
| 4 separate charts (`aks/`, `bm/`, `eks/`, `oc/`) | 1 chart (`tracebloc/`) with platform toggles |
| Hardcoded `tracebloc-secrets` | `{{ .Release.Name }}-secrets` via helper |
| `default` ServiceAccount | Dedicated `{{ .Release.Name }}-jobs-manager` SA |
| No standard labels | Kubernetes recommended labels on all resources |
| Monolithic `mysql-client-deployment.yaml` | Split into `mysql-deployment.yaml`, `mysql-configmap.yaml`, `mysql-service.yaml` |
| Unused `namespace` value in `values.yaml` | Removed — use `helm install -n <ns>` |

## Key Value Mapping

### AKS → Unified

No structural changes. Add platform-specific storage values:

```yaml
# values-aks.yaml
storageClass:
  create: true
  provisioner: file.csi.azure.com
  parameters:
    skuName: Standard_LRS
  mountOptions:
    - dir_mode=0750
    - file_mode=0640
    - uid=999
    - gid=999
    - mfsymlinks
    - cache=strict
    - actimeo=30

clusterScope: true
```

### EKS → Unified

```yaml
# values-eks.yaml
storageClass:
  create: true
  provisioner: efs.csi.aws.com
  volumeBindingMode: Immediate
  reclaimPolicy: Retain
  mountOptions:
    - actimeo=30
  parameters:
    directoryPerms: "700"
    uid: "999"
    gid: "999"
    fileSystemId: <YOUR_EFS_FILESYSTEM_ID>
    provisioningMode: efs-ap

clusterScope: true
```

### Bare-Metal → Unified

Key change: `hostPath` section replaces per-PVC `hostPath` values.

```yaml
# values-bm.yaml
hostPath:
  enabled: true

pvcAccessMode: ReadWriteOnce

storageClass:
  create: true
  provisioner: kubernetes.io/no-provisioner

clusterScope: true
```

**PV paths (fixed):** When `hostPath.enabled` is true, PVs use `/tracebloc/data`, `/tracebloc/logs`, `/tracebloc/mysql` (e.g. map to `~/.tracebloc/{data,logs,mysql}` when that dir is mounted at `/tracebloc`).

### OpenShift → Unified

```yaml
# values-oc.yaml
storageClass:
  create: false
  name: ocs-storagecluster-cephfs  # or your existing SC

clusterScope: false  # namespace-scoped RBAC

openshift:
  scc:
    enabled: true  # creates the resource-monitor SCC
```

## Migration Steps

### 1. Export current values

```bash
helm get values <release-name> -n <namespace> -o yaml > old-values.yaml
```

### 2. Create new values file

Map old values to the unified schema (see tables above). Credentials stay the same.

### 3. Dry-run the upgrade

```bash
helm template <release-name> ./client -n <namespace> -f new-values.yaml > new-manifests.yaml
```

Compare with current manifests:

```bash
helm get manifest <release-name> -n <namespace> > old-manifests.yaml
diff old-manifests.yaml new-manifests.yaml
```

### 4. Key differences to expect

- **Resource names**: Secret name changes from `tracebloc-secrets` to `<release>-secrets`
- **Labels**: All resources get standard `app.kubernetes.io/*` labels
- **ServiceAccount**: Dedicated SA instead of `default`

### 5. Apply the migration

```bash
# Uninstall old release (PVCs are protected with helm.sh/resource-policy: keep)
helm uninstall <release-name> -n <namespace>

# Install with new chart
helm install <release-name> ./client -n <namespace> -f new-values.yaml
```

> **Important:** PVCs have `helm.sh/resource-policy: keep` so they survive `helm uninstall`. Verify PVCs still exist before installing the new chart.

### 6. Clean up pre-Helm `resource-monitor` remnants

Some early-era edges were installed with a `resource-monitor` DaemonSet deployed via raw `kubectl apply` — **before** the per-platform charts existed. The live manifest has no Helm ownership annotations (`meta.helm.sh/release-*`), and its pods are named `resource-monitor-<suffix>` (not `tracebloc-resource-monitor-<suffix>`).

The unified chart's `tracebloc-resource-monitor` DaemonSet supersedes it. After migrating, delete the legacy resources so the namespace has a single node-level agent and isn't carrying an unmanaged, hostPath-mounting pod that blocks PSA `enforce=restricted`:

```bash
# Check whether your cluster has the legacy DS
kubectl -n <namespace> get ds resource-monitor 2>/dev/null

# If present, delete it and its cluster-scoped RBAC (all four names are exact).
# The ClusterRole/Binding are global — verify they aren't shared by any other workload first:
kubectl get clusterrolebinding resource-monitor -o jsonpath='{.subjects}'
# Expect a single subject: ServiceAccount/resource-monitor in <namespace>.

kubectl -n <namespace> delete ds resource-monitor
kubectl -n <namespace> delete sa resource-monitor
kubectl delete clusterrolebinding resource-monitor
kubectl delete clusterrole resource-monitor
```

The chart-managed `tracebloc-resource-monitor` keeps running throughout; no rollout is triggered.

## Rollback

The legacy per-platform chart directories (`aks/`, `bm/`, `eks/`, `oc/`) were
removed from the repo in #70 once the unified chart had been validated across
every supported platform. If you must install one of those legacy charts,
recover the directory from git history at the deletion commit:

```bash
# find the SHA where the legacy dirs were last present
git log --diff-filter=D --summary -- aks bm eks oc | head
git checkout <pre-delete-sha> -- aks bm eks oc
helm install <release-name> ./<old-chart> -n <namespace> -f old-values.yaml
```

In practice, rolling back *within* the unified chart family is the safer
path — `helm rollback <release-name> <revision>` keeps the cluster on a
chart it has been exercising.
