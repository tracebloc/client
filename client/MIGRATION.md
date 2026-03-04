# Migration Guide: Per-Platform Charts → Unified `tracebloc` Chart

This guide explains how to migrate from the legacy per-platform charts (`aks/`, `bm/`, `eks/`, `oc/`) to the unified `client/` chart.

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
  dataPath: /path/to/shared_data
  logsPath: /path/to/logs
  mysqlPath: /path/to/mysql
  initJob: true

pvcAccessMode: ReadWriteOnce

storageClass:
  create: true
  provisioner: kubernetes.io/no-provisioner

clusterScope: true
```

**Old → New mapping:**
| Old key | New key |
|---------|---------|
| `clientData.hostPath` | `/tracebloc/` + `hostPath.dataDir` (base path is hardcoded) |
| `clientLogsPvc.hostPath` | `/tracebloc/` + `hostPath.logsDir` (base path is hardcoded) |
| `mysqlPvc.hostPath` | `/tracebloc/` + `hostPath.mysqlDir` (base path is hardcoded) |

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

## Rollback

The old charts remain in `aks/`, `bm/`, `eks/`, `oc/` and can be used at any time:

```bash
helm uninstall <release-name> -n <namespace>
helm install <release-name> ./<old-chart> -n <namespace> -f old-values.yaml
```
