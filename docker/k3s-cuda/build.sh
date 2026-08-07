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

# Always build + LOAD locally first (even when publishing) so we can VERIFY the rootfs
# before anything is pushed.
docker buildx build \
  --build-arg "K3S_TAG=${K3S_TAG}" \
  --build-arg "CUDA_TAG=${CUDA_TAG}" \
  --platform "${PLATFORM}" \
  -t "${IMAGE}" \
  --load \
  .

# Verify the k3s rootfs overlay actually landed at / — a mis-parsed `COPY --exclude` (trailing
# flag, or wrong path) copies the rootfs under /--exclude=... and lets the build "succeed" with
# a broken image (#616 Bugbot). Export the flattened image filesystem and assert its structure;
# no in-image shell is needed (the overlay can replace /bin).
echo "Verifying rootfs layout..."
cid="$(docker create "${IMAGE}")"
rootfs="$(mktemp)"
docker export "${cid}" | tar -tf - > "${rootfs}"
docker rm -f "${cid}" >/dev/null
if grep -qE '(^|/)--exclude' "${rootfs}"; then
  echo "ERROR: image contains a '--exclude' path — COPY --exclude was mis-parsed as a destination:" >&2
  grep -E '(^|/)--exclude' "${rootfs}" | head >&2
  rm -f "${rootfs}"; exit 1
fi
# k3s lands at usr/bin/k3s (copied into /usr/bin via the kept /bin symlink) or bin/k3s.
if ! grep -qE '(^|/)bin/k3s$' "${rootfs}"; then
  echo "ERROR: k3s binary (…bin/k3s) missing — rootfs not overlaid correctly." >&2
  rm -f "${rootfs}"; exit 1
fi
rm -f "${rootfs}"
echo "rootfs verify OK"

if [[ "${PUSH}" == "true" ]]; then
  docker push "${IMAGE}"
fi
echo "Done: ${IMAGE}"
