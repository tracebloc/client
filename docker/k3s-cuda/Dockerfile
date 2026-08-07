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
# (scripts/spec/facts.env / scripts/lib/common.sh) so a GPU node runs the exact
# same validated k3s as a normal CPU node. scripts/check-facts.sh enforces this:
# this ARG, build.sh, and the workflow input default are all checked against
# facts.env's K8S_VERSION, so a bump can't leave the GPU image tag stale (#547).
ARG K3S_TAG="v1.29.4-k3s1"
ARG CUDA_TAG="12.4.1-base-ubuntu22.04"

FROM rancher/k3s:${K3S_TAG} AS k3s

FROM nvcr.io/nvidia/cuda:${CUDA_TAG}

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
    && apt-get install -y --no-install-recommends nvidia-container-toolkit \
    && nvidia-ctk runtime configure --runtime=containerd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the pinned k3s rootfs over the CUDA base, then bring in k3s's own /bin explicitly.
# --exclude MUST come BEFORE the src/dest: a TRAILING `--exclude` is parsed as the
# destination, so the rootfs silently copies to /--exclude=... instead of / — the build
# "passes" but the image is broken (Bugbot). The exclude path is RELATIVE to the source
# (`bin`, not `/bin`): excluding k3s's real /bin dir avoids colliding with the CUDA base's
# merged-/usr /bin symlink (which would else error "cannot copy to non-directory"), while
# keeping the Ubuntu userland (curl/apt/nvidia-ctk). build.sh verifies the overlay landed
# at / after the build, so a mis-parse can never publish a broken image.
COPY --from=k3s --exclude=bin / /
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
