# OpenShift configuration for tracebloc (oc chart)

Use these steps so the **tracebloc** namespace works with the oc Helm chart on OpenShift (networking, RBAC, storage).

---

## 1. Create the tracebloc namespace (if needed)

```bash
oc create namespace tracebloc
# Or use your chosen namespace name and set it in values (namespace: <your-namespace>)
```

---

## 2. Fix Multus CNI "Unauthorized" for the tracebloc namespace

If pods stay in `ContainerCreating` with **error adding pod to CNI network "multus-cni-network" … Unauthorized**, Multus is not allowed to manage networking for that namespace. Do one of the following.

### Option A: Add namespace to Multus global namespaces (cluster admin)

1. Open the Multus daemon ConfigMap:

   ```bash
   oc edit configmap multus-daemon-config -n openshift-multus
   ```

2. In the `data` section, find the Multus config (e.g. `config` or the key that holds the CNI config JSON).

3. Add `tracebloc` to **globalNamespaces** (exact key name may vary; often a comma-separated list):

   - If you see something like:
     ```json
     "globalNamespaces": "default,openshift-multus,openshift-sriov-network-operator,openshift-cnv"
     ```
   - Change it to:
     ```json
     "globalNamespaces": "default,openshift-multus,openshift-sriov-network-operator,openshift-cnv,tracebloc"
     ```

4. Save and exit. Multus will pick up the change (may take a short time or a rollout of the multus daemon).

### Option B: Use default / allowed namespace

If you cannot change Multus config, deploy the chart in a namespace that is already allowed (e.g. `default`):

```bash
helm install tracebloc ./oc -n default -f value_files/values-oc-sandbox-cisco.yaml
# and set namespace: default in your values, or use -n default and ensure all resources target that namespace
```

### Option C: Check API server / ServiceAccount (if Option A doesn’t apply)

"Unauthorized" can also be due to Multus not being able to call the API (e.g. SA token or certs). A cluster admin should:

- Confirm the **multus** ServiceAccount in `openshift-multus` can get/list pods in **tracebloc** (or cluster-wide, depending on your setup).
- Check for 403/429 on API calls from Multus and fix RBAC or rate limits.
- See [Red Hat solution 7097348](https://access.redhat.com/solutions/7097348) (and related) for pod networking / Multus issues.

---

## 3. RBAC (namespaced – no cluster-admin)

The oc chart is set up to use **namespaced** RBAC (Role/RoleBinding) so the installer does not need cluster-admin:

- In values: `clusterRole.useClusterScope: false` (default for oc).
- Ensure the user installing the chart has permission in the target namespace to create Role, RoleBinding, Deployment, Pod, PVC, Secret, ConfigMap, Service, etc.

No extra RBAC steps are required if you install with a user that can create those resources in `tracebloc`.

---

## 4. Storage (PVCs and StorageClass)

- **StorageClass:** Set `storageClass.name` in values to a StorageClass that exists in the cluster (e.g. `crc-csi-hostpath-provisioner`, `efs-sc`, or your OpenShift storage class). Set `storageClass.create: false` if you are not creating a new StorageClass.
- **WaitForFirstConsumer:** If the StorageClass uses `volumeBindingMode: WaitForFirstConsumer`, the logs PVC will stay Pending until a pod that mounts it is created. The oc chart mounts the logs PVC in the jobs-manager deployment so it can bind.

---

## 5. Resource monitor and Pod Security (hostPath + custom SCC)

The **resource monitor** DaemonSet mounts host `/proc` and `/sys` (read-only) to collect node-level metrics (CPU, memory, disk, GPU). This requires a `hostPath` volume, which is blocked by OpenShift's default **restricted** SCC.

The chart ships a **custom SecurityContextConstraint** (`resource-monitor-scc.yaml`) that is automatically created when `resourceMonitor.enabled: true`. It follows the principle of least privilege:

- Allows `hostPath` **only** for `/proc` and `/sys`, **read-only**
- No privileged container, no privilege escalation, all capabilities dropped
- Must run as non-root, seccomp `runtime/default` enforced
- No host network, ports, PID, or IPC
- Bound to the `tracebloc-resource-monitor` ServiceAccount via both the SCC `users` field **and** RBAC (`ClusterRole`/`ClusterRoleBinding` with `use` verb — the recommended OpenShift 4.x approach)
- Pod spec sets `hostUsers: false` (required by `restricted-v3` SCC)

This is the same pattern used by Prometheus Node Exporter, cAdvisor, and NVIDIA DCGM in production OpenShift clusters.

**Option A – Keep resource monitor disabled (no SCC needed)**

```yaml
resourceMonitor:
  enabled: false
```

**Option B – Enable resource monitor (recommended for node metrics)**

1. **Enable in values:**

   ```yaml
   resourceMonitor:
     enabled: true
   ```

2. **The installer needs permission to create cluster-scoped resources:** `SecurityContextConstraints`, `ClusterRole`, and `ClusterRoleBinding`. On CRC, `kubeadmin` has this by default. In production, the installer typically needs cluster-admin or a role that can create these specific resources. The custom SCC is minimal and scoped to a single ServiceAccount; it does **not** weaken the entire namespace.

3. **Suppress PodSecurity warnings** (optional). The namespace can stay `restricted`; the SCC handles the exception. To silence the audit/warn messages:

   ```bash
   oc label namespace tracebloc pod-security.kubernetes.io/audit=baseline --overwrite
   oc label namespace tracebloc pod-security.kubernetes.io/warn=baseline --overwrite
   # enforce stays restricted — the SCC overrides it for the specific SA
   ```

4. **Verify the SCC is created and bound:**

   ```bash
   # Check SCC exists
   oc get scc | grep tracebloc-resource-monitor

   # Check RBAC binding exists
   oc get clusterrole | grep tracebloc-resource-monitor-scc
   oc get clusterrolebinding | grep tracebloc-resource-monitor-scc

   # Check which SCC the pod is actually using (look for openshift.io/scc annotation)
   oc get pods -n tracebloc -l app=tracebloc-resource-monitor -o yaml | grep "scc"

   # Check SA can use the SCC
   oc adm policy who-can use scc tracebloc-resource-monitor-<release-name>
   ```

5. **Troubleshooting:** If pods still fail with SCC errors after `helm upgrade`:

   ```bash
   # Verify Helm created all resources (SCC is cluster-scoped, listed separately)
   helm get manifest <release-name> -n <namespace> | grep "kind: SecurityContextConstraints" -A5

   # Delete and reinstall the DaemonSet to force re-evaluation
   oc delete daemonset tracebloc-resource-monitor -n <namespace>
   helm upgrade <release-name> ./oc -n <namespace> -f <your-values>.yaml
   ```

**CRC (local development) note:** CRC ships a single node with `kubeadmin` which has full cluster-admin. The custom SCC works identically — no extra steps needed beyond enabling `resourceMonitor.enabled: true` and running `helm upgrade`.

---

## 6. Install / upgrade the chart

From the repo root:

```bash
# Install
helm install tracebloc ./oc -n tracebloc -f value_files/values-oc-sandbox-cisco.yaml

# Or upgrade
helm upgrade tracebloc ./oc -n tracebloc -f value_files/values-oc-sandbox-cisco.yaml
```

Use your own values file and namespace as needed.

---

## 7. Verify

```bash
oc get pods -n tracebloc
oc get pvc -n tracebloc
oc get deployment -n tracebloc
```

Pods should reach `Running` and PVCs `Bound` once Multus is authorized for the namespace and storage is provisioned.

---

## Summary checklist

| Item | Action |
|------|--------|
| Namespace | Create `tracebloc` (or use an allowed namespace) |
| Multus "Unauthorized" | Add `tracebloc` to Multus globalNamespaces (Option A) or deploy in an allowed namespace (Option B) |
| RBAC | Use default `useClusterScope: false`; installer needs namespace-scoped create rights |
| Storage | Set `storageClass.name` to existing class; logs PVC is mounted by jobs-manager |
| Resource monitor / hostPath | Keep `resourceMonitor.enabled: false`, or set `enabled: true` — the chart creates a minimal custom SCC (see §5) |
| Install | `helm install tracebloc ./oc -n tracebloc -f <your-values>.yaml` |
