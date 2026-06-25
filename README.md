[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE) [![Docker](https://img.shields.io/badge/docker-tracebloc%2Fclient-2496ED.svg)](https://hub.docker.com/r/tracebloc/client) [![Platform](https://img.shields.io/badge/platform-tracebloc-00C9A7.svg)](https://ai.tracebloc.io)

# tracebloc Client 🔒

The runtime that keeps your data where it belongs — on your infrastructure.

The tracebloc client deploys inside your Kubernetes cluster and executes all model training, fine-tuning, and inference locally. It connects to the tracebloc backend for orchestration only. No data, no model weights, no artifacts ever leave your environment.

## Architecture

```
Your infrastructure
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   ┌──────────────────┐      ┌───────────────────────┐   │
│   │  tracebloc        │      │  Kubernetes cluster   │   │
│   │  client           │◄────►│                       │   │
│   │                   │      │  ● Training jobs      │   │
│   │  Orchestrates     │      │  ● Inference jobs     │   │
│   │  training,        │      │  ● Your datasets      │   │
│   │  enforces budgets │      │  ● Fine-tuned weights │   │
│   └────────┬──────────┘      │                       │   │
│            │                 │  Everything stays here │   │
│            │                 └───────────────────────┘   │
└────────────┼────────────────────────────────────────────┘
             │
             │ Encrypted (orchestration only — no data)
             ▼
    ┌─────────────────┐
    │  tracebloc       │
    │  backend         │
    │                  │
    │  Coordinates     │
    │  experiments,    │
    │  serves web UI   │
    └─────────────────┘
```

## What the client manages

- **Training execution** — runs vendor models in isolated, containerized sandboxes
- **Compute budgets** — enforces per-vendor FLOPs or runtime quotas
- **Security boundaries** — namespace isolation, encrypted communication, audit logging
- **Multi-framework support** — PyTorch, TensorFlow, custom containers
- **Hardware scheduling** — CPUs, GPUs, TPUs via Kubernetes-native orchestration

## Security

For the threat model, defense layers, per-platform caveats, operator responsibilities, and verification steps, see **[docs/SECURITY.md](docs/SECURITY.md)**. The chart ships hardened defaults against untrusted user-submitted ML code; deployment still requires a CNI that enforces NetworkPolicy — that file explains exactly what to check.

## Deploy

This repo ships the **tracebloc** unified Helm chart (currently `v1.3.5`) — one chart for AKS, EKS, bare-metal, and OpenShift.

### Quick install

A single command provisions a Kubernetes cluster, auto-detects and installs GPU drivers (NVIDIA or AMD), deploys the tracebloc client, and installs the [tracebloc CLI](https://github.com/tracebloc/cli) (`tracebloc dataset push`). Use this when you don't already have a cluster — the result is a full client install, not a demo.

**macOS / Linux**

```bash
bash <(curl -fsSL https://tracebloc.io/i.sh)
```

**Windows** *(PowerShell as Administrator)*

```powershell
irm https://tracebloc.io/i.ps1 | iex
```

The installer pulls helper scripts from this repo at runtime — see [`scripts/install-k8s.sh`](scripts/install-k8s.sh) and [`scripts/install-k8s.ps1`](scripts/install-k8s.ps1). Those scripts are pinned to an **immutable release tag** and each is **verified against a cosign-signed manifest** before it runs; the install **fails closed** if verification can't complete (it never silently runs unverified code). See [docs/SUPPLY_CHAIN.md](docs/SUPPLY_CHAIN.md) for the integrity model and how to verify a release by hand.

### Helm install

For existing Kubernetes clusters:

```bash
helm repo add tracebloc https://tracebloc.github.io/client
helm repo update
helm install my-tracebloc tracebloc/client \
  --namespace tracebloc --create-namespace \
  -f my-values.yaml
```

Full deployment guide → **[docs/INSTALL.md](docs/INSTALL.md)** (prerequisites, required values, upgrade & rollback, air-gapped install).

## Ingest a dataset

Once the client is running, get a dataset into your cluster's local MySQL with ~8 lines of YAML and a single `helm install`. No Dockerfile, no Python script — the platform owns the official image, you describe what you want ingested.

The flow is two steps. **First**, stage your raw files on the cluster's shared PVC (`client-pvc` by default, mounted at `/data/shared/` inside the ingestor Pod). The chart doesn't transport data into the cluster — it points at data the cluster can already see. The simplest pattern is a throwaway `kubectl cp` Pod that mounts the PVC; the chart README links the manifest.

**Second**, describe the dataset and install:

```yaml
# my-cats-dogs.yaml
apiVersion: tracebloc.io/v1
kind: IngestConfig
category: image_classification
table: cats_dogs_train
intent: train
csv: /data/shared/cats-dogs/labels.csv
images: /data/shared/cats-dogs/images/
label: label
```

```bash
helm install my-cats-dogs tracebloc/ingestor \
  --namespace tracebloc \
  --set-file ingestConfig=./my-cats-dogs.yaml
```

The ingestor runs once, validates the data, copies files into the destination directory on the PVC, inserts rows into the cluster's MySQL, sends metadata to the tracebloc backend — then exits. The chart artifacts (ConfigMap + post-install hook Job) become inert; nothing keeps running. Repeat per dataset.

Full ingestor docs → **[ingestor/README.md](ingestor/README.md)** (data staging patterns, every supported category, the schema, the update model, verification, override knobs).

| Topic | Where to look |
|---|---|
| Production install + required values | [docs/INSTALL.md](docs/INSTALL.md) |
| Ingest a dataset (declarative YAML) | [ingestor/README.md](ingestor/README.md) |
| Available ingestion categories + example YAMLs | [tracebloc/data-ingestors templates](https://github.com/tracebloc/data-ingestors/tree/master/templates) |
| Threat model & operator responsibilities | [docs/SECURITY.md](docs/SECURITY.md) |
| Migrating from `eks-1.0.x` / `aks-*` charts to `client-1.x` | [docs/MIGRATIONS.md](docs/MIGRATIONS.md) |
| Per-tenant migration runbook | [docs/migration-tools/README.md](docs/migration-tools/README.md) |
| Per-platform value mapping | [client/MIGRATION.md](client/MIGRATION.md) |

Platform-specific walkthroughs: [Linux](https://docs.tracebloc.io/environment-setup/local-deployment-guide-linux) · [macOS](https://docs.tracebloc.io/environment-setup/local-deployment-guide-macos) · [EKS](https://docs.tracebloc.io/environment-setup/eks-client-deployment-guide) · [Azure / AKS](https://docs.tracebloc.io/environment-setup/azure-deployment-guide)

> **NetworkPolicy required.** The chart's training-pod egress lockdown only takes effect on a CNI that enforces NetworkPolicy. See [SECURITY.md § Per-platform caveats](docs/SECURITY.md#5-per-platform-caveats).

## Links

[Platform](https://ai.tracebloc.io/) · [Docs](https://docs.tracebloc.io/) · [Discord](https://discord.gg/tracebloc)

## License

Apache 2.0 — see [LICENSE](LICENSE).

**Deployment help?** [support@tracebloc.io](mailto:support@tracebloc.io) or [open an issue](https://github.com/tracebloc/client/issues).
