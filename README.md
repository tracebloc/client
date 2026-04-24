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

```bash
docker pull tracebloc/client:latest
```

Deployment varies by infrastructure. Follow the guide for your setup:

- [Deployment overview](https://docs.tracebloc.io/environment-setup/deployment-overview)
- [Local — Linux](https://docs.tracebloc.io/environment-setup/local-linux)
- [Local — macOS](https://docs.tracebloc.io/environment-setup/local-macos)
- [AWS](https://docs.tracebloc.io/environment-setup/aws)

Full documentation → [docs.tracebloc.io](https://docs.tracebloc.io/)

## Links

[Platform](https://ai.tracebloc.io/) · [Docs](https://docs.tracebloc.io/) · [Discord](https://discord.gg/tracebloc)

## License

Apache 2.0 — see [LICENSE](LICENSE).

**Deployment help?** [support@tracebloc.io](mailto:support@tracebloc.io) or [open an issue](https://github.com/tracebloc/client/issues).
