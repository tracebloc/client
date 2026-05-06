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

This repo ships the **tracebloc** unified Helm chart (currently `v1.3.1`) — one chart for AKS, EKS, bare-metal, and OpenShift.

### Quick install

A single command provisions a Kubernetes cluster, auto-detects and installs GPU drivers (NVIDIA or AMD), and deploys the tracebloc client. Use this when you don't already have a cluster — the result is a full client install, not a demo.

**macOS / Linux**

```bash
bash <(curl -fsSL tracebloc.io/i.sh)
```

**Windows** *(PowerShell as Administrator)*

```powershell
irm tracebloc.io/i.ps1 | iex
```

The installer pulls helper scripts from this repo at runtime — see [`scripts/install-k8s.sh`](scripts/install-k8s.sh) and [`scripts/install-k8s.ps1`](scripts/install-k8s.ps1).

### Helm install

For existing Kubernetes clusters:

```bash
helm repo add tracebloc https://tracebloc.github.io/client
helm repo update
helm install my-tracebloc tracebloc/tracebloc \
  --namespace tracebloc --create-namespace \
  -f my-values.yaml
```

Full deployment guide → **[docs/INSTALL.md](docs/INSTALL.md)** (prerequisites, required values, upgrade & rollback, air-gapped install).

| Topic | Where to look |
|---|---|
| Production install + required values | [docs/INSTALL.md](docs/INSTALL.md) |
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
