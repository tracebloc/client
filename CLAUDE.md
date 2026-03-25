# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Kubernetes/Helm deployment charts for the tracebloc client -- the on-premise runtime that executes ML training, fine-tuning, and inference inside a customer's Kubernetes cluster. It connects to the tracebloc backend for orchestration only; no data leaves the customer's environment.

## Supported platforms

AKS (Azure), EKS (AWS), bare-metal, and OpenShift. A single unified chart (`client/`) handles all platforms via `values.yaml` toggles. Legacy per-platform charts (`aks/`, `bm/`) are deprecated but still present.

## Chart structure

```
client/                  # Unified chart (use this one)
  Chart.yaml             # apiVersion v2, appVersion 1.0.3, requires K8s >=1.24
  values.yaml            # Default values with platform toggles
  ci/                    # Per-platform CI value overrides (aks, bm, eks, oc)
  templates/             # K8s manifests (jobs-manager, mysql, rbac, storage, PVCs, secrets)
  tests/                 # Helm unit tests
  MIGRATION.md           # Guide for migrating from legacy per-platform charts
aks/, bm/                # Legacy per-platform charts (deprecated)
```

## Key configuration knobs

- `hostPath.enabled` -- true for bare-metal (hostPath PVs), false for cloud (dynamic PVCs)
- `storageClass.create` / `storageClass.provisioner` -- per-platform storage provisioner
- `clusterScope` -- true for ClusterRole, false for namespace-scoped (OpenShift without cluster-admin)
- `openshift.scc.enabled` -- SecurityContextConstraints for resource monitor on OpenShift
- `clientId` / `clientPassword` -- tracebloc credentials
- `dockerRegistry` -- optional private registry credentials

## Helm commands

```bash
# Template/dry-run
helm template <release> ./client -n <ns> -f ci/aks-values.yaml

# Install
helm install <release> ./client -n <ns> -f ci/aks-values.yaml \
  --set clientId=<ID> --set clientPassword=<PW>

# Upgrade
helm upgrade <release> ./client -n <ns> -f ci/aks-values.yaml

# Run chart tests
helm test <release> -n <ns>
```

## CI

GitHub Actions workflows in `.github/workflows/`: `helm-ci.yaml` (linting/testing) and `release-helm-chart.yaml` (packaging/publishing).
