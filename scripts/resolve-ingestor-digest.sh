#!/usr/bin/env bash
# resolve-ingestor-digest.sh — resolve the multi-arch index digest for the
# spawned ingestor image and (optionally) write it into the prod overlay.
#
# backend#1028: prod installs pin `images.ingestor.digest` for reproducibility
# (see client/values-prod.yaml). The floating tag (read from the chart's
# images.ingestor.tag) moves as new patches ship, so the pinned digest must
# be re-resolved every time the prod
# ingestor line is cut. This helper does that resolution against the live
# registry so the pin is never hand-typed.
#
# Usage:
#   scripts/resolve-ingestor-digest.sh [TAG]           # print repo@digest
#   scripts/resolve-ingestor-digest.sh [TAG] --write   # patch values-prod.yaml
#
# TAG defaults to `images.ingestor.tag` read from client/values.yaml (via yq
# if present, else a portable yq-free parse). If it cannot be determined, the
# script fails loudly — it never falls back to a hardcoded tag.
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

# Portable, yq-free reader for images.ingestor.tag from a values.yaml.
# Scoped to the images: -> ingestor: block so a sibling image's `tag:`
# (jobsManager / podsMonitor / requestsProxy / ... each carry their own)
# can never be picked up by mistake. bash-3.2 / macOS-safe (pure awk).
read_ingestor_tag() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    # Enter the top-level images: block.
    /^images:[[:space:]]*$/ { in_images = 1; next }
    # Any other top-level key (col 0, not a comment) closes it.
    /^[^[:space:]#]/        { in_images = 0; in_ingestor = 0 }
    in_images {
      # A 2-space sibling key under images: — arm the ingestor scope only
      # while we are inside ingestor:, disarm on the next sibling.
      if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        in_ingestor = ($0 ~ /^  ingestor:[[:space:]]*$/) ? 1 : 0
        next
      }
      # The 4-space tag: leaf inside ingestor:.
      if (in_ingestor && $0 ~ /^    tag:[[:space:]]/) {
        v = $0
        sub(/^    tag:[[:space:]]*/, "", v)          # drop the key
        sub(/[[:space:]]+#.*$/, "", v)               # drop a trailing comment
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)   # trim
        gsub(/^"|"$/, "", v)                         # unwrap double quotes
        gsub(/^'\''|'\''$/, "", v)                   # unwrap single quotes
        print v
        exit
      }
    }
  ' "$file"
}

if [[ -z "$tag" ]]; then
  # No explicit TAG arg → default to the chart's images.ingestor.tag so this
  # helper always resolves the SAME line the chart ships. NEVER hardcode a
  # tag here: a stale constant would silently pin the WRONG (older) digest
  # after the chart tag moves (e.g. 0.7 -> 0.8) while appearing to follow the
  # chart. Prefer yq; fall back to the portable yq-free parse above; if
  # neither can determine it, fail loudly rather than guess.
  if command -v yq >/dev/null 2>&1 && [[ -f "$chart_values" ]]; then
    tag="$(yq -r '.images.ingestor.tag' "$chart_values")"
    [[ "$tag" == "null" ]] && tag=""   # yq prints literal "null" for a missing key
  else
    tag="$(read_ingestor_tag "$chart_values" || true)"
  fi
  if [[ -z "$tag" ]]; then
    echo "ERROR: could not determine the default ingestor tag from ${chart_values#$here/../}." >&2
    echo "       (images.ingestor.tag was unreadable: file missing, key absent, or yq not" >&2
    echo "        installed and the yq-free parse found nothing.)" >&2
    echo "       Fix: pass TAG explicitly — scripts/resolve-ingestor-digest.sh <TAG> [--write] —" >&2
    echo "       or install yq. Refusing to fall back to a hardcoded tag." >&2
    exit 1
  fi
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
# `|| true`: under `set -o pipefail`, an inspect failure or a `grep -v` that
# filters every line exits non-zero and would abort the whole script — even
# though the digest is already resolved. Tolerate it: an empty `platforms`
# then trips multiarch=0 below, so the guard still fires (ERROR under --write,
# WARNING otherwise) instead of the run dying silently with no digest line.
platforms="$(docker buildx imagetools inspect "$resolved" 2>/dev/null \
  | awk '/Platform:/ {print $2}' | grep -v '^unknown' | sort -u | tr '\n' ' ')" || true
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
