#!/usr/bin/env bash
# =============================================================================
#  Build (and optionally push) the custom k3s-CUDA node image  (#616)
# =============================================================================
# See ./Dockerfile for WHY this image is needed. Env knobs:
#   K3S_TAG           k3s tag — MUST match the installer's K8S_VERSION pin
#   CUDA_TAG          NVIDIA CUDA base tag
#   IMAGE_REGISTRY    default ghcr.io
#   IMAGE_REPOSITORY  default tracebloc/k3s-cuda
#   PLATFORM          default linux/amd64 (NVIDIA GPU nodes)
#   PUSH              "true" to push, otherwise build+load locally
set -euo pipefail

K3S_TAG="${K3S_TAG:-v1.29.4-k3s1}"
CUDA_TAG="${CUDA_TAG:-12.4.1-base-ubuntu22.04}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-tracebloc/k3s-cuda}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH="${PUSH:-false}"

# The tag encodes BOTH the k3s pin and the CUDA base, so a new k8s pin can never
# silently reuse a stale GPU image, and the installer can derive it from
# K8S_VERSION deterministically.
TAG="${K3S_TAG}-cuda-${CUDA_TAG}"
IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${TAG}"

cd "$(dirname "$0")"
echo "Building ${IMAGE}  (k3s=${K3S_TAG} cuda=${CUDA_TAG} platform=${PLATFORM} push=${PUSH})"

args=(build
  --build-arg "K3S_TAG=${K3S_TAG}"
  --build-arg "CUDA_TAG=${CUDA_TAG}"
  --platform "${PLATFORM}"
  -t "${IMAGE}"
  .)
if [[ "${PUSH}" == "true" ]]; then
  docker buildx "${args[@]}" --push
else
  docker buildx "${args[@]}" --load
fi
echo "Done: ${IMAGE}"
