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

K3S_TAG="${K3S_TAG:-v1.36.3-k3s1}"
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
  # Here-string, NOT `grep … | head >&2`: under this script's `set -euo pipefail`
  # head closes the pipe after its 10th line, so a rootfs with enough matching
  # paths to push grep's output past the ~64KB pipe buffer makes grep take
  # SIGPIPE → the pipeline exits 141 → errexit aborts HERE, skipping the
  # `rm -f` below and the intended `exit 1`: the diagnostic killed the error
  # path it exists to explain, leaking the extracted rootfs and reporting 141
  # instead of 1. Measured: 50 matching lines exit 1 (fits the buffer, no
  # signal), 20k exit 141. Same idiom and reasoning as
  # scripts/lib/install-client-helm.sh (see its herestring note) and the rc=141
  # case in .github's conformance-gate.
  matches="$(grep -E '(^|/)--exclude' "${rootfs}" || true)"
  head -n 10 <<< "${matches}" >&2
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
