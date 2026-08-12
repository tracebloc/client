#!/usr/bin/env bats
# GPU node-image embed drift guard (#616).
#
# install-k8s.ps1 embeds docker/k3s-cuda/{Dockerfile,nvidia-runtimeclass.yaml,
# k3d-entrypoint-tracebloc-cdi.sh} as base64 ($script:K3S_CUDA_*_B64) so the SIGNED bootstrap can
# build the GPU node image locally without fetching anything unsigned. That means the same content
# lives in two places, and nothing about check-facts.sh catches it: check-facts guards the version
# PINS (K3S_TAG/CUDA_TAG), not whole-file embedding, and Get-GpuBuildContentHash only hashes the
# EMBEDDED copies (for local-build caching) — it never compares them to the repo files. So a future
# edit to docker/k3s-cuda/* that isn't re-embedded would silently diverge: the workflow-published
# image and the installer's local build would differ, with nothing failing. That is exactly the
# drift class #435/#547 close one level up.
#
# A Pester suite already asserts this (install-k8s.Tests.ps1, "Embedded GPU build inputs stay in
# sync with docker/k3s-cuda"), and it runs in CI on BOTH windows-latest and ubuntu-latest. This
# bats mirror exists so the invariant is also verifiable by a reviewer with no pwsh installed —
# review ergonomics, plus a second net in the bash-side job. Requested in review on #633.

load test_helper

setup() {
  PS1_FILE="${SCRIPTS_DIR}/install-k8s.ps1"
  CUDA_DIR="$(cd "${SCRIPTS_DIR}/../docker/k3s-cuda" && pwd)"
}

# Decode one $script:<VAR> = '<base64>' blob out of install-k8s.ps1.
# base64 -d is GNU/coreutils and modern macOS; -D is the older BSD spelling.
_decode_embed() {
  local var="$1" b64
  b64="$(grep -oE "\\\$script:${var} = '[A-Za-z0-9+/=]+'" "$PS1_FILE" | sed -E "s/^.*'([A-Za-z0-9+\/=]+)'\$/\1/")"
  [ -n "$b64" ] || return 1
  printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D 2>/dev/null
}

# Compare decoded embed against the repo file, normalising CRLF and trailing newlines only.
_assert_embed_matches() {
  local var="$1" file="$2" got want
  got="$(_decode_embed "$var" | tr -d '\r')" || return 1
  want="$(tr -d '\r' < "${CUDA_DIR}/${file}")" || return 1
  if [ "$got" != "$want" ]; then
    echo "EMBED DRIFT: \$script:${var} does not match docker/k3s-cuda/${file}" >&2
    echo "Re-embed it (base64 of the file) in scripts/install-k8s.ps1 and regenerate scripts/manifest.sha256." >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -25 >&2 || true
    return 1
  fi
}

@test "embedded Dockerfile matches docker/k3s-cuda/Dockerfile" {
  _assert_embed_matches "K3S_CUDA_DOCKERFILE_B64" "Dockerfile" || return 1
}

@test "embedded RuntimeClass matches docker/k3s-cuda/nvidia-runtimeclass.yaml" {
  _assert_embed_matches "K3S_CUDA_RUNTIMECLASS_B64" "nvidia-runtimeclass.yaml" || return 1
}

@test "embedded CDI drop-in matches docker/k3s-cuda/k3d-entrypoint-tracebloc-cdi.sh" {
  _assert_embed_matches "K3S_CUDA_BOOT_B64" "k3d-entrypoint-tracebloc-cdi.sh" || return 1
}

@test "every embedded blob decodes to something non-empty (catches a truncated re-embed)" {
  for v in K3S_CUDA_DOCKERFILE_B64 K3S_CUDA_RUNTIMECLASS_B64 K3S_CUDA_BOOT_B64; do
    run _decode_embed "$v"
    [ "$status" -eq 0 ] || return 1
    [ -n "$output" ] || return 1
  done
}

@test "the embedded drop-in is the k3d ENTRYPOINT DROP-IN shape, not an entrypoint wrapper" {
  # k3d replaces the image ENTRYPOINT with its own, so the drop-in must RETURN (never exec k3s)
  # and always exit 0 — k3d runs drop-ins with `|| exit 1`, so a non-zero exit aborts the node
  # and fails cluster-create instead of degrading to CPU. This shipped broken once (#616).
  local body
  body="$(_decode_embed K3S_CUDA_BOOT_B64)" || return 1
  [[ "$body" != *"exec /bin/k3s"* ]] || return 1
  [[ "$body" == *"exit 0"* ]] || return 1
}
