#!/usr/bin/env bash
# resolve-ingestor-digest.sh — resolve the multi-arch index digest for the
# spawned ingestor image and (optionally) write it into the prod overlay.
#
# backend#1028: prod installs pin `images.ingestor.digest` for reproducibility
# (see client/values-prod.yaml). The floating tag (default `0.7`) moves as new
# patches ship, so the pinned digest must be re-resolved every time the prod
# ingestor line is cut. This helper does that resolution against the live
# registry so the pin is never hand-typed.
#
# Usage:
#   scripts/resolve-ingestor-digest.sh [TAG]           # print repo@digest
#   scripts/resolve-ingestor-digest.sh [TAG] --write   # patch values-prod.yaml
#
# TAG defaults to `images.ingestor.tag` from client/values.yaml.
# REPO override: INGESTOR_REPO=ghcr.io/tracebloc/ingestor (default).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart_values="$here/../client/values.yaml"
prod_overlay="$here/../client/values-prod.yaml"

repo="${INGESTOR_REPO:-ghcr.io/tracebloc/ingestor}"
tag="${1:-}"
write=0
[[ "${1:-}" == "--write" ]] && { tag=""; write=1; }
[[ "${2:-}" == "--write" ]] && write=1

if [[ -z "$tag" ]]; then
  if command -v yq >/dev/null 2>&1 && [[ -f "$chart_values" ]]; then
    tag="$(yq -r '.images.ingestor.tag' "$chart_values")"
  fi
  tag="${tag:-0.7}"
fi

ref="${repo}:${tag}"

# Resolve the top-level (index) digest. Prefer buildx imagetools (prints the
# manifest-list/index digest directly); fall back to `docker manifest inspect`.
digest=""
if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
  digest="$(docker buildx imagetools inspect "$ref" 2>/dev/null \
    | awk '/^Digest:/ {print $2; exit}')"
fi
if [[ -z "$digest" ]]; then
  digest="$(docker manifest inspect --verbose "$ref" 2>/dev/null \
    | grep -m1 '"Ref"' | sed -E 's/.*@(sha256:[a-f0-9]{64}).*/\1/')" || true
fi

if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "ERROR: could not resolve a digest for $ref (registry auth / network?)." >&2
  exit 1
fi

# Sanity: the pinned image must be a multi-arch index (amd64 + arm64), or
# ingestion breaks on arm64 hosts (client#186). Mirror the helm-ci
# `ingestor-multiarch` guard, and inspect the RESOLVED index (repo@digest) —
# i.e. the exact thing we would pin — not the floating repo:tag.
resolved="${repo}@${digest}"
platforms="$(docker buildx imagetools inspect "$resolved" 2>/dev/null \
  | awk '/Platform:/ {print $2}' | grep -v '^unknown' | sort -u | tr '\n' ' ')"
multiarch=1
grep -q 'linux/amd64' <<<"$platforms" || multiarch=0
grep -q 'linux/arm64' <<<"$platforms" || multiarch=0
if [[ "$multiarch" -eq 0 ]]; then
  if [[ "$write" == 1 ]]; then
    # A prod pin MUST be multi-arch: helm-ci hard-fails a single-arch digest,
    # and a committed arch-specific pin breaks ingestion on the other arch.
    echo "ERROR: $resolved is not a linux/amd64 + linux/arm64 multi-arch index (saw: ${platforms:-none})." >&2
    echo "       Refusing to pin a single-arch digest into the prod overlay (client#186 / #160)." >&2
    echo "       helm-ci's ingestor-multiarch guard would reject this pin at CI time." >&2
    exit 1
  fi
  echo "WARNING: $resolved is not a linux/amd64 + linux/arm64 multi-arch index (saw: ${platforms:-none})." >&2
  echo "         Pinning an arch-specific digest breaks ingestion on the other arch (client#186)." >&2
fi

echo "${repo}@${digest}  (tag ${tag}; platforms: ${platforms:-unknown})"

if [[ "$write" == 1 ]]; then
  [[ -f "$prod_overlay" ]] || { echo "ERROR: $prod_overlay not found." >&2; exit 1; }
  # Replace the digest value on the `digest:` line under images.ingestor.
  tmp="$(mktemp)"
  sed -E "s|(^[[:space:]]*digest:[[:space:]]*\").*(\")|\1${digest}\2|" "$prod_overlay" >"$tmp"
  mv "$tmp" "$prod_overlay"
  # Verify the sed actually landed: if the overlay's digest line has drifted
  # from the expected `digest: "…"` format, sed matches nothing and silently
  # leaves the file unchanged. Confirm the intended digest is now present
  # before reporting success.
  if ! grep -q "digest:[[:space:]]*\"${digest}\"" "$prod_overlay"; then
    echo "ERROR: ${prod_overlay#$here/../} was not patched — no matching digest line found." >&2
    echo "       Expected a line of the form:  digest: \"${digest}\"" >&2
    echo "       Fix the overlay's digest line to that format and re-run." >&2
    exit 1
  fi
  echo "Wrote ${digest} to ${prod_overlay#$here/../}" >&2
fi
