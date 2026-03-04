# DEPRECATED

This chart (`oc/`) has been superseded by the **unified `client/` chart**.

The unified chart supports AKS, EKS, bare-metal, and OpenShift from a single set of templates, reducing duplication and maintenance burden.

## Migration

See [`client/MIGRATION.md`](../client/MIGRATION.md) for step-by-step migration instructions.

Key changes for OpenShift:
- Set `clusterRole.useClusterScope: false` for namespace-scoped RBAC
- Set `openshift.scc.enabled: true` for the resource monitor SCC

## Timeline

- This chart will be kept for one release cycle after all environments are migrated.
- It will be removed in the next major version.

## For new deployments

Use the unified chart:

```bash
helm install <release> ./client -n <namespace> -f values-oc.yaml
```
