# Custom k3s-CUDA node image (GPU-enabled edges — #616)

The stock `rancher/k3s` image is Alpine-based and has **no NVIDIA container
runtime**, so GPU pods can never schedule on it (the node advertises
`0 nvidia.com/gpu`). This directory builds a drop-in replacement k3s node image
that:

1. rebuilds the **same pinned k3s** (`K3S_TAG`, matched to the installer's
   `K8S_VERSION`) on an NVIDIA CUDA Ubuntu base,
2. installs the NVIDIA Container Toolkit, configures containerd for the `nvidia`
   runtime, and puts that runtime in **CDI mode**,
3. bakes in the `nvidia` `RuntimeClass`, and
4. generates a **WSL CDI spec at node boot** (`tracebloc-cdi-boot.sh`).

Based on the official [k3d CUDA recipe](https://k3d.io/v5.7.4/usage/advanced/cuda/),
plus the WSL2 findings below.

## Why CDI, and why no device plugin (Docker Desktop / WSL2)

On Docker Desktop the GPU reaches WSL2 **paravirtualized** (`/dev/dxg` + a
WSL-specific driver store), not through the usual `/dev/nvidia*` interface. Two
consequences, both validated on real hardware (RTX 4050, driver 532.10):

* The **NVIDIA k8s device plugin cannot work here** — `nvmlInit()` returns
  `ERROR_NOT_SUPPORTED`, so it registers 0 GPUs. Worse, because it owns the
  `nvidia.com/gpu` extended resource it would hold the node at 0 and strand every
  job. So this image ships **only the RuntimeClass**; the installer advertises
  `nvidia.com/gpu` itself via a node-status patch (`Set-NodeGpuCapacity`).
* **CUDA itself works fine** via CDI. `nvidia-ctk cdi generate --mode=wsl` maps
  `/dev/dxg` + the WSL `libcuda`/`libnvidia-ml` into the pod. It must run **at
  boot**, not at build time: the driver-store path contains a per-machine hash.
  One gap the generator has: it **omits `libdxcore.so`** (that lives in the
  standard lib path, not the driver store), and without it `libcuda` loads but
  can't reach `/dev/dxg` — surfacing as a misleading *"CUDA driver version is
  insufficient for CUDA runtime version"*. The boot script injects it.

The boot script is a strict no-op when `/dev/dxg` is absent, so a native-Linux
node behaves exactly as before (there, the standard device plugin path applies).

## How it's used

When a GPU is detected **and** verified usable, `scripts/install-k8s.ps1`
creates the k3d cluster with `--image <this image> --gpus=all` (instead of
`rancher/k3s:<K8S_VERSION>`) and sets `RUNTIME_CLASS_NAME=nvidia` so every
spawned training pod runs under the `nvidia` RuntimeClass. If the GPU can't be
wired up, the installer falls back to the stock image and CPU (see #616 Layer 1).

## Build

```bash
# local build (no push)
K3S_TAG=v1.29.4-k3s1 ./build.sh

# build + push to ghcr.io/tracebloc/k3s-cuda:<k3s>-cuda-<cuda>
PUSH=true ./build.sh
```

Or run the **build-k3s-cuda** GitHub workflow (manual `workflow_dispatch`; set
`push: true` to publish).

## Version pinning

`K3S_TAG` **must** equal the installer's `K8S_VERSION`
(`scripts/lib/common.sh`). The image tag encodes both the k3s pin and the CUDA
base — e.g. `v1.29.4-k3s1-cuda-12.4.1-base-ubuntu22.04` — so a new k8s pin can
never silently reuse a stale GPU image. Bump both together.
