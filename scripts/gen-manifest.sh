#!/usr/bin/env bash
# =============================================================================
#  gen-manifest.sh — produce scripts/manifest.sha256 (RFC-0001 R8, backend#889)
#
#  The bootstrap (scripts/install.sh) verifies every sub-script it fetches
#  against this manifest before running the privileged steps. This script
#  regenerates the manifest from the exact set the bootstrap fetches, so the
#  two never drift.
#
#  The manifest is the *integrity surface*; its *authenticity* is established
#  separately by a cosign keyless signature over this file, produced by the
#  release workflow (see docs/SUPPLY_CHAIN.md). This script does NOT sign — it
#  only computes digests, so it needs no secrets and is safe to run anywhere
#  (locally to preview, in CI to publish).
#
#  Usage:
#    scripts/gen-manifest.sh            # write scripts/manifest.sha256
#    scripts/gen-manifest.sh --check    # verify the committed manifest is current
#                                       #   (CI gate; non-zero on drift)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The single source of truth for what the bootstrap fetches. Keep in lockstep
# with the FILES array in scripts/install.sh — the --check mode below fails CI
# if a file the bootstrap fetches is missing from this list (or vice versa).
FILES=(
  "scripts/install-k8s.sh"
  "scripts/lib/common.sh"
  "scripts/lib/preflight.sh"
  "scripts/lib/detect-gpu.sh"
  "scripts/lib/gpu-nvidia.sh"
  "scripts/lib/gpu-amd.sh"
  "scripts/lib/setup-macos.sh"
  "scripts/lib/setup-linux.sh"
  "scripts/lib/cluster.sh"
  "scripts/lib/gpu-plugins.sh"
  "scripts/lib/install-client-helm.sh"
  "scripts/lib/install-cli.sh"
  "scripts/lib/provision.sh"
  "scripts/lib/summary.sh"
  "scripts/lib/diagnose.sh"
)

MANIFEST="scripts/manifest.sha256"

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "[ERROR] no sha256sum / shasum on PATH" >&2
    exit 1
  fi
}

# Cross-check: the bootstrap's FILES array must match this one exactly, or the
# manifest will be missing an entry for something the bootstrap runs (or carry
# a stale one). Extract the array from install.sh and diff.
_check_bootstrap_in_sync() {
  local boot
  boot="$(awk '/^FILES=\(/{f=1;next} /^\)/{f=0} f' scripts/install.sh \
            | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  local here
  here="$(printf '%s\n' "${FILES[@]}")"
  if [[ "$boot" != "$here" ]]; then
    echo "[ERROR] scripts/install.sh FILES array and gen-manifest.sh FILES differ:" >&2
    diff <(printf '%s\n' "$here") <(printf '%s\n' "$boot") >&2 || true
    exit 1
  fi
}

generate() {
  local f
  {
    for f in "${FILES[@]}"; do
      [[ -f "$f" ]] || { echo "[ERROR] missing file: $f" >&2; exit 1; }
      printf '%s  %s\n' "$(_sha256_of "$f")" "$f"
    done
  } > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
}

_check_bootstrap_in_sync

if [[ "${1:-}" == "--check" ]]; then
  generate_to="$(mktemp)"
  trap 'rm -f "$generate_to"' EXIT
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "[ERROR] missing file: $f" >&2; exit 1; }
    printf '%s  %s\n' "$(_sha256_of "$f")" "$f"
  done > "$generate_to"
  if ! diff -u "$MANIFEST" "$generate_to" >/dev/null 2>&1; then
    echo "[ERROR] $MANIFEST is out of date. Run scripts/gen-manifest.sh and commit." >&2
    diff -u "$MANIFEST" "$generate_to" >&2 || true
    exit 1
  fi
  echo "$MANIFEST is up to date."
  exit 0
fi

generate
echo "Wrote $MANIFEST:"
cat "$MANIFEST"
