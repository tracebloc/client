# DEPRECATED

This chart (`eks/`) has been superseded by the **unified `tracebloc/` chart**.

The unified chart supports AKS, EKS, bare-metal, and OpenShift from a single set of templates, reducing duplication and maintenance burden.

## Migration

See [`tracebloc/MIGRATION.md`](../tracebloc/MIGRATION.md) for step-by-step migration instructions.

## Timeline

- This chart will be kept for one release cycle after all environments are migrated.
- It will be removed in the next major version.

## For new deployments

Use the unified chart:

```bash
helm install <release> ./tracebloc -n <namespace> -f values-eks.yaml
```
