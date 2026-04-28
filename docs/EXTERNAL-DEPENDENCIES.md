# Client External Dependencies

This document lists every external endpoint the tracebloc client contacts, split by when it's needed. Use this to configure firewalls, proxy allowlists, and air-gapped deployments.

---

## Runtime Dependencies (post-install)

These endpoints are contacted while the client is running. **Both are required for normal operation.**

### 1. Docker Hub — Container Image Registry

| Detail | Value |
|--------|-------|
| **Endpoint** | `docker.io` / `registry-1.docker.io` |
| **Protocol** | HTTPS (port 443) |
| **When** | Every time a training job is launched |
| **Why** | The jobs-manager dynamically spawns training containers. The image path is constructed using the `JOB_IMAGE_HOST` env var (default: `docker.io/`) plus the task-specific image name (e.g., `tracebloc/image-classification-gpu`). |
| **imagePullPolicy** | `Always` (hardcoded in all deployment templates) |
| **Auth** | Docker registry credentials via `imagePullSecrets` (configured in `docker-registry-secret.yaml`) |

**Images pulled at runtime:**
- `tracebloc/jobs-manager:{CLIENT_ENV}`
- `tracebloc/pods-monitor:{CLIENT_ENV}`
- `tracebloc/resource-monitor:{CLIENT_ENV}`
- `tracebloc/mysql-client:latest`
- `busybox:1.35` (MySQL init containers)
- Task-specific training images (spawned dynamically by jobs-manager)

**Air-gapped note:** To run without Docker Hub access, pre-pull all required images onto cluster nodes and change `imagePullPolicy` to `IfNotPresent` in the deployment templates. You can also point `JOB_IMAGE_HOST` to a private registry mirror.

### 2. tracebloc Backend API

| Detail | Value |
|--------|-------|
| **Endpoint** | Configured at install time (e.g., `https://api.tracebloc.io`) |
| **Protocol** | HTTPS (port 443) |
| **When** | Continuously during operation |
| **Why** | Authentication, experiment orchestration, model weight upload/download, dataset metadata, status reporting |
| **Auth** | `CLIENT_ID` / `CLIENT_PASSWORD` passed as env vars from Kubernetes secret, exchanged for a token via `POST /api-token-auth/` |

**API endpoints consumed:**
- `POST /api-token-auth/` — authentication
- `GET /download/weights:{model}/{exp_id}/{cycle}/` — download model weights
- `GET /download/model:{model}/{exp_id}/{cycle}/` — download model code
- `POST /upload/` — upload trained weights
- `GET /global_meta/global_metadata/{table}/` — dataset schema
- `GET /get_image_ids/{dataset}/{exp}/{test}/` — image IDs for training

---

## Install-time Only Dependencies

These are only contacted during initial cluster setup (`scripts/install.sh` or `scripts/lib/setup-*.sh`). They are **not needed after installation is complete.**

### Cluster Tooling

| Component | URL | Script |
|-----------|-----|--------|
| Docker Engine | `https://get.docker.com` | `setup-linux.sh` |
| kubectl binary | `https://dl.k8s.io/release/{ver}/bin/linux/{arch}/kubectl` | `setup-linux.sh` |
| kubectl checksum | `https://dl.k8s.io/release/{ver}/bin/linux/{arch}/kubectl.sha256` | `setup-linux.sh` |
| K8s stable version | `https://dl.k8s.io/release/stable.txt` | `setup-linux.sh` |
| Helm 3 | `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3` | `setup-linux.sh` |
| k3d | `https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh` | `setup-linux.sh` |
| Homebrew (macOS) | `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` | `setup-macos.sh` |
| Docker Desktop (macOS) | `https://desktop.docker.com/mac/main/{arch}/Docker.dmg` | `setup-macos.sh` |

### GPU Drivers & Plugins

| Component | URL | Script |
|-----------|-----|--------|
| NVIDIA device plugin | `https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml` | `gpu-plugins.sh` |
| AMD device plugin | `https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/v1.0.0/k8s-ds-amdgpu-dp.yaml` | `gpu-plugins.sh` |
| NVIDIA GPG key | `https://nvidia.github.io/libnvidia-container/gpgkey` | `gpu-nvidia.sh` |
| NVIDIA container toolkit (DEB) | `https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list` | `gpu-nvidia.sh` |
| NVIDIA container toolkit (RPM) | `https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo` | `gpu-nvidia.sh` |
| NVIDIA CUDA repo | `https://developer.download.nvidia.com/compute/cuda/repos/...` | `gpu-nvidia.sh` |
| AMD ROCm repo | `https://repo.radeon.com/amdgpu-install/latest` | `gpu-amd.sh` |

### Helm Chart Distribution

| Component | URL | Script |
|-----------|-----|--------|
| tracebloc Helm repo | `https://tracebloc.github.io/client` | `install-client-helm.sh` |

---

## CI/CD Only (not on customer infrastructure)

These are used in GitHub Actions CI pipelines and never run on customer clusters.

| Component | Source |
|-----------|--------|
| `actions/checkout@v4` | GitHub Actions |
| `azure/setup-helm@v4` | GitHub Actions |
| `actions/upload-artifact@v4` | GitHub Actions |
| `actions/download-artifact@v4` | GitHub Actions |
| `softprops/action-gh-release@v2` | GitHub Actions |
| `helm-unittest/helm-unittest` v0.5.2 | GitHub |
| kubeconform | `https://github.com/yannh/kubeconform/releases/...` |

---

## Fully Internal (never leaves the cluster)

| Component | Details |
|-----------|---------|
| MySQL | `mysql-client:3306` — internal ClusterIP service |
| Training/test data | Stored on shared PVC, never transmitted externally |
| Model weights | Local until explicitly uploaded to backend API |
| Kubernetes API | RBAC, metrics, pod/job management — all cluster-internal |

---

## Firewall Allowlist (minimum for runtime)

For a running client, allow outbound HTTPS (443) to:

```
# Required
<your-tracebloc-backend-url>    # e.g., api.tracebloc.io

# Required unless images are pre-pulled
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
```

Everything else can be blocked after installation is complete.
