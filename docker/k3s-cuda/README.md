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
4. generates a **WSL CDI spec at node boot** (`k3d-entrypoint-tracebloc-cdi.sh`).

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
node behaves exactly as before — there, the standard **device plugin** path
applies (see below).

## Native Linux (client#835)

On native Linux the paravirtualized WSL path does not apply: `/dev/nvidia*` are
exposed into the node by `--gpus=all`, the **NVML device plugin works**, and it
(not a node patch) advertises `nvidia.com/gpu`. Two things make that path work,
and both are done by the installer — **no image rebuild is required** for a
native-Linux GPU install:

1. **Native CDI spec.** containerd here runs the NVIDIA runtime in **CDI mode**,
   and this image's boot drop-in only generates a spec on WSL2. So right after
   cluster-create the Linux installer runs, inside each node,
   `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
   (`scripts/lib/cluster.sh::_generate_node_cdi_specs`). The spec persists in the
   node's writable layer and is regenerated on any recreate.
2. **Device plugin under the `nvidia` RuntimeClass.** The chart's NVML device
   plugin can only enumerate GPUs if its own pod runs under the NVIDIA runtime, so
   the installer sets `gpu.devicePlugin.nvidia.runtimeClassName=nvidia` (the
   RuntimeClass baked into this image) when the GPU is wired.

If either step can't complete, the installer falls back to CPU rather than
advertising a GPU pods can't use.

## How it's used

When a GPU is detected **and** wired into the cluster, **both** installers create
the k3d cluster with `--image <this image> --gpus=all` (instead of
`rancher/k3s:<K8S_VERSION>`) and set `RUNTIME_CLASS_NAME=nvidia` so every spawned
training pod runs under the `nvidia` RuntimeClass:

* **Linux** — `scripts/lib/cluster.sh` (`_gpu_node_image` derives the pull ref;
  `_create_new_cluster` swaps the image; `_generate_node_cdi_specs` writes the CDI
  spec; the reuse guard falls back to CPU on a stock node).
* **Windows/WSL2** — `scripts/install-k8s.ps1` (builds this image locally from the
  embedded build context; advertises `nvidia.com/gpu` via a node-status patch, no
  device plugin).

If the GPU can't be wired up, either installer falls back to the stock image and
CPU (see #616 Layer 1 / #835).

## Verifying GPU on a Linux host

The unit + template suites cover the installer wiring; the end-to-end GPU path
needs a real NVIDIA Linux host. After a GPU install (`GPU_VENDOR=nvidia`), confirm:

```bash
# 1. The node runs the GPU-capable image, not stock rancher/k3s
docker inspect k3d-tracebloc-server-0 --format '{{.Config.Image}}'   # …/k3s-cuda:<k8s>-cuda-<base>

# 2. The native CDI spec was generated in the node
docker exec k3d-tracebloc-server-0 test -s /etc/cdi/nvidia.yaml && echo "CDI spec present"

# 3. The `nvidia` RuntimeClass exists and the device plugin is Running
kubectl get runtimeclass nvidia
kubectl -n kube-system get ds nvidia-device-plugin-daemonset

# 4. The node ADVERTISES the GPU (was 0/empty before #835)
kubectl get node k3d-tracebloc-server-0 -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'   # -> 1 (or more)

# 5. A GPU pod schedules and runs
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"runtimeClassName":"nvidia"}}' \
  --limits='nvidia.com/gpu=1' -- nvidia-smi   # -> the GPU table
```

Before #835 step 4 returned empty ("No devices found" in the plugin log) and the
installer still printed the "GPU access" claim; after it, the claim is true.

## Build

```bash
# local build (no push)
K3S_TAG=v1.36.3-k3s1 ./build.sh

# build + push to ghcr.io/tracebloc/k3s-cuda:<k3s>-cuda-<cuda>
PUSH=true ./build.sh
```

Or run the **build-k3s-cuda** GitHub workflow (manual `workflow_dispatch`; set
`push: true` to publish).

## Version pinning

`K3S_TAG` **must** equal the installer's `K8S_VERSION`
(`scripts/lib/common.sh`). The image tag encodes both the k3s pin and the CUDA
base — e.g. `v1.36.3-k3s1-cuda-12.4.1-base-ubuntu22.04` — so a new k8s pin can
never silently reuse a stale GPU image. Bump both together.
