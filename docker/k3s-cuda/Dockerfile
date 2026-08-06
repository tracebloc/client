# syntax=docker/dockerfile:1.7-labs
# =============================================================================
#  Custom k3s node image with NVIDIA GPU support  (tracebloc/client #616)
# =============================================================================
# WHY this exists: the stock `rancher/k3s` image is Alpine-based and ships NO
# NVIDIA container runtime, so GPU pods can never schedule on it — the node
# advertises 0 nvidia.com/gpu. This image rebuilds the SAME pinned k3s on an
# NVIDIA CUDA Ubuntu base, installs the NVIDIA Container Toolkit, configures
# containerd for the `nvidia` runtime, and bakes in the device-plugin +
# `nvidia` RuntimeClass so the node advertises nvidia.com/gpu on first boot.
# Based on the official k3d CUDA recipe (https://k3d.io/.../usage/advanced/cuda/).
#
# IMPORTANT: K3S_TAG MUST match the installer's K8S_VERSION pin
# (scripts/lib/common.sh: K8S_VERSION) so a GPU node runs the exact same
# validated k3s as a normal CPU node. The build workflow enforces this.
ARG K3S_TAG="v1.29.4-k3s1"
ARG CUDA_TAG="12.4.1-base-ubuntu22.04"

FROM rancher/k3s:${K3S_TAG} AS k3s

FROM nvcr.io/nvidia/cuda:${CUDA_TAG}

# NVIDIA Container Toolkit, then point containerd at the `nvidia` runtime. The
# gpg key + apt list are pinned via the keyring the same way the in-WSL toolkit
# install does (scripts/install-k8s.ps1) so a restricted-network mirror can
# re-home them consistently.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
         | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
         | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
         | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nvidia-container-toolkit \
    && nvidia-ctk runtime configure --runtime=containerd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the pinned k3s rootfs over the CUDA base. Exclude /bin on the first copy
# so the Ubuntu userland (curl, apt, nvidia-ctk) survives, then bring in k3s's
# own /bin (the k3s binary + /bin/aux) explicitly — the official recipe's split.
COPY --from=k3s --exclude=/bin / /
COPY --from=k3s /bin /bin

# Auto-deploy the NVIDIA device plugin + `nvidia` RuntimeClass on first server
# boot (k3s auto-applies manifests dropped here). This is what makes the node
# advertise nvidia.com/gpu without a separate `kubectl apply`.
COPY nvidia-device-plugin-daemonset.yaml /var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml

VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log

ENV PATH="$PATH:/bin/aux"

ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]
