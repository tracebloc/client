# syntax=docker/dockerfile:1.7-labs
# =============================================================================
#  Custom k3s node image with NVIDIA GPU support  (tracebloc/client #616)
# =============================================================================
# WHY this exists: the stock `rancher/k3s` image is Alpine-based and ships NO
# NVIDIA container runtime, so GPU pods can never schedule on it — the node
# advertises 0 nvidia.com/gpu. This image rebuilds the SAME pinned k3s on an
# NVIDIA CUDA Ubuntu base, installs the NVIDIA Container Toolkit, configures
# containerd for the `nvidia` runtime (in CDI mode), and bakes in the `nvidia`
# RuntimeClass plus a k3d entrypoint drop-in that generates the WSL CDI spec on
# every node start. GPU capacity is advertised by the installer + that drop-in --
# NOT by the NVML device plugin, which cannot work on WSL2 (see README).
# Based on the official k3d CUDA recipe (https://k3d.io/.../usage/advanced/cuda/).
#
# IMPORTANT: K3S_TAG MUST match the installer's K8S_VERSION pin
# (scripts/spec/facts.env / scripts/lib/common.sh) so a GPU node runs the exact
# same validated k3s as a normal CPU node. scripts/check-facts.sh enforces this:
# this ARG, build.sh, and the workflow input default are all checked against
# facts.env's K8S_VERSION, so a bump can't leave the GPU image tag stale (#547).
ARG K3S_TAG="v1.29.4-k3s1"
ARG CUDA_TAG="12.4.1-base-ubuntu22.04"
# NVIDIA Container Toolkit version. PINNED to the build validated on real hardware (an RTX 4050
# laptop, driver 532.10) because the whole WSL2 GPU path depends on version-sensitive surfaces:
# `cdi generate --mode=wsl`, `config --set nvidia-container-runtime.mode=cdi`, and the exact YAML
# the generator emits (our libdxcore injection parses it). Unpinned, two machines built weeks
# apart could get different toolkit builds and behave differently -- and a future release changing
# the spec shape would break GPU on new installs while existing ones kept working.
# The install below FALLS BACK to the latest if this version has aged out of the apt repo, so a
# stale pin degrades to "unpinned" rather than failing the build (which would cost GPU entirely).
ARG NCT_VERSION="1.19.1-1"

FROM rancher/k3s:${K3S_TAG} AS k3s

FROM nvcr.io/nvidia/cuda:${CUDA_TAG}

# The CUDA base bakes in NVIDIA_REQUIRE_CUDA (e.g. cuda>=12.4); with --gpus the container runtime
# then REFUSES to start this node on any driver older than that base ("unsatisfied condition:
# cuda>=12.4"), so a valid GPU on a slightly older driver (e.g. 532.x = CUDA 12.1) can't run the
# cluster at all. This node runs k3s, not CUDA workloads -- the real CUDA/driver compatibility is
# enforced per-pod by each TRAINING image -- so disable the requirement gate here (#616).
ENV NVIDIA_DISABLE_REQUIRE=1

# NVIDIA Container Toolkit, then point containerd at the `nvidia` runtime. The
# gpg key + apt list are pinned via the keyring the same way the in-WSL toolkit
# install does (scripts/install-k8s.ps1) so a restricted-network mirror can
# re-home them consistently. curl carries the TLS floor + bounded timeouts inline
# (a Dockerfile can't source common.sh's curl_secure()) so a stalled or downgraded
# connection to nvidia.github.io fails fast instead of hanging the build (house rule).
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 60 https://nvidia.github.io/libnvidia-container/gpgkey \
         | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 60 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
         | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
         | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update \
    && ( apt-get install -y --no-install-recommends "nvidia-container-toolkit=${NCT_VERSION}" \
         || { echo "NCT ${NCT_VERSION} unavailable in the repo -- falling back to latest"; \
              apt-get install -y --no-install-recommends nvidia-container-toolkit; } ) \
    && nvidia-ctk --version \
    && nvidia-ctk runtime configure --runtime=containerd \
    && nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the pinned k3s rootfs over the CUDA base, then bring in k3s's own /bin explicitly.
# --exclude MUST come BEFORE the src/dest: a TRAILING `--exclude` is parsed as the
# destination, so the rootfs silently copies to /--exclude=... instead of / — the build
# "passes" but the image is broken (Bugbot). Paths are RELATIVE to the source (`bin`, not
# `/bin`). Ubuntu 22.04 is merged-/usr, so /bin /sbin /lib /lib64 are SYMLINKS to /usr/*,
# while the Alpine k3s image ships them as real dirs — copying those over the symlinks errors
# "cannot copy to non-directory". k3s is a STATIC binary (needs no shared libs), so we exclude
# all four (keeping Ubuntu's glibc userland: curl/apt/nvidia-ctk) and overlay only k3s's own
# /bin (the static k3s + /bin/aux) into /usr/bin via the kept /bin symlink. build.sh verifies
# the overlay landed correctly after the build, so a mis-parse can never publish a broken image.
COPY --from=k3s \
     --exclude=bin --exclude=sbin --exclude=lib --exclude=lib32 --exclude=lib64 --exclude=libx32 \
     --exclude=var/run --exclude=var/lock \
     / /
COPY --from=k3s /bin /bin

# Auto-deploy ONLY the `nvidia` RuntimeClass on first server boot (k3s auto-applies
# manifests dropped here). We deliberately do NOT ship the NVML device-plugin DaemonSet:
# on Docker Desktop/WSL2 it can't init NVML, would register 0 GPUs, and (owning the
# nvidia.com/gpu extended resource) would overwrite the installer's node-resource patch
# with 0 -- stranding jobs. GPU capacity is advertised by the installer via a node patch,
# and pods get the real GPU through the CDI spec generated at boot (see k3d-entrypoint-tracebloc-cdi.sh).
COPY nvidia-runtimeclass.yaml /var/lib/rancher/k3s/server/manifests/nvidia-runtimeclass.yaml

# Node GPU setup: generate the WSL CDI spec (+ libdxcore) and keep nvidia.com/gpu
# advertised, so pods can use the GPU on Docker Desktop/WSL2. No-op on non-WSL2 nodes.
#
# It MUST be installed as a /bin/k3d-entrypoint-*.sh DROP-IN, not as the image ENTRYPOINT:
# k3d replaces the image entrypoint with its own /bin/k3d-entrypoint.sh, which runs these
# drop-ins and then execs k3s. An ENTRYPOINT wrapper here is silently never run (#616).
COPY k3d-entrypoint-tracebloc-cdi.sh /bin/k3d-entrypoint-tracebloc-cdi.sh
RUN chmod +x /bin/k3d-entrypoint-tracebloc-cdi.sh

VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log

ENV PATH="$PATH:/bin/aux"

# Stock k3s entrypoint (same as rancher/k3s). k3d overrides it with its own
# /bin/k3d-entrypoint.sh, which runs our drop-in above before exec'ing k3s; keeping the
# stock value means the image also behaves normally outside k3d.
ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]
