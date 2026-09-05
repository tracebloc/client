#!/usr/bin/env bash
# resolve-ingestor-digest.sh — resolve the multi-arch index digest for the
# spawned ingestor image and (optionally) write it into the chart's prod pin.
#
# backend#1028: prod installs pin the ingestor image for reproducibility. The
# floating tag (read from the chart's images.ingestor.tag) moves as new patches
# ship, so the pinned digest must be re-resolved every time the prod ingestor
# line is cut. This helper does that resolution against the live registry so
# the pin is never hand-typed.
#
# backend#1245: the pin lives in `images.ingestor.prodDigest` in the chart's
# DEFAULT client/values.yaml — not in an install-time `-f` overlay. Only a chart
# default survives the fleet's `helm upgrade --reset-then-reuse-values`, which
# adopts new chart defaults but re-applies stored user-supplied values; the old
# client/values-prod.yaml overlay could never reach an installed edge and has
# been removed. --write therefore patches values.yaml.
#
# Usage:
#   scripts/resolve-ingestor-digest.sh [TAG]           # print repo@digest
#   scripts/resolve-ingestor-digest.sh [TAG] --write   # patch prodDigest in
#                                                      #   client/values.yaml
#
# After --write, BUMP client/Chart.yaml (version + appVersion): the chart only
# publishes on a version change, so an unbumped refresh reaches no edge.
#
# TAG defaults to `images.ingestor.tag` read from client/values.yaml (via yq
# if present, else a portable yq-free parse). If it cannot be determined, the
# script fails loudly — it never falls back to a hardcoded tag.
# REPO override: INGESTOR_REPO=ghcr.io/tracebloc/ingestor (default).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart_values="$here/../client/values.yaml"

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

# Portable, yq-free reader for images.ingestor.channelTags.prod. Same scoping
# discipline as read_ingestor_tag: only the 6-space `prod:` leaf inside
# images: -> ingestor: -> channelTags: can match, so no sibling key can be
# picked up by mistake. bash-3.2 / macOS-safe.
read_ingestor_prod_channel() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    /^images:[[:space:]]*$/ { in_images = 1; next }
    /^[^[:space:]#]/        { in_images = 0; in_ingestor = 0; in_channels = 0 }
    in_images {
      if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        in_ingestor = ($0 ~ /^  ingestor:[[:space:]]*$/) ? 1 : 0
        in_channels = 0
        next
      }
      if (in_ingestor && $0 ~ /^    [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        in_channels = ($0 ~ /^    channelTags:[[:space:]]*$/) ? 1 : 0
        next
      }
      if (in_channels && $0 ~ /^      prod:[[:space:]]*/) {
        line = $0
        sub(/^      prod:[[:space:]]*/, "", line)     # drop the key
        sub(/[[:space:]]+#.*$/, "", line)              # drop a trailing comment
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)  # trim
        gsub(/^"|"$/, "", line)                        # unwrap double quotes
        gsub(/^'"'"'|'"'"'$/, "", line)                        # unwrap single quotes
        if (line != "") { print line; exit }
      }
    }
  ' "$file"
}

# Portable, yq-free reader for `serviceDbAccountsByEnv.prod` (true/false).
# Same shape as the readers above: scoped to the top-level block so a
# sibling `prod:` leaf (channelTags.prod, imageTags.prod, ...) can never be
# mistaken for it. Prints nothing when the key is absent.
read_prod_service_db_accounts() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    /^serviceDbAccountsByEnv:[[:space:]]*$/ { in_block = 1; next }
    /^[^[:space:]#]/                        { in_block = 0 }
    in_block && $0 ~ /^[[:space:]]+prod:[[:space:]]*(true|false)[[:space:]]*$/ {
      sub(/^[[:space:]]+prod:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print; exit
    }
  ' "$file"
}

# Portable, yq-free reader for `images.ingestor.ackDrift.line` — the channel
# line an ACKNOWLEDGED-DRIFT hold is declared against (backend#2673). A non-empty
# result means the prod pin is DELIBERATELY parked behind its float across a
# compatibility boundary and must NOT be advanced to the float. Same scoping
# discipline as read_ingestor_prod_channel: only the 6-space `line:` leaf inside
# images: -> ingestor: -> ackDrift: can match, so a sibling `line:`/`prod:` cannot
# be picked up by mistake. Prints nothing when no hold is declared. macOS-safe.
read_prod_pin_ackdrift_line() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    /^images:[[:space:]]*$/ { in_images = 1; next }
    /^[^[:space:]#]/        { in_images = 0; in_ingestor = 0; in_ack = 0 }
    in_images {
      if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        in_ingestor = ($0 ~ /^  ingestor:[[:space:]]*$/) ? 1 : 0
        in_ack = 0
        next
      }
      if (in_ingestor && $0 ~ /^    [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        in_ack = ($0 ~ /^    ackDrift:[[:space:]]*$/) ? 1 : 0
        next
      }
      if (in_ack && $0 ~ /^      line:[[:space:]]*/) {
        line = $0
        sub(/^      line:[[:space:]]*/, "", line)      # drop the key
        sub(/[[:space:]]+#.*$/, "", line)              # drop a trailing comment
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)  # trim
        gsub(/^"|"$/, "", line)                        # unwrap double quotes
        gsub(/^'\''|'\''$/, "", line)                  # unwrap single quotes
        if (line != "") { print line; exit }
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
  # Since backend#1360 `images.ingestor.tag` is an OVERRIDE that is empty by
  # default, and the prod float lives in `images.ingestor.channelTags.prod`.
  # This script resolves the PROD pin, so prefer the explicit override when an
  # operator set one and otherwise read the prod channel. Without this the
  # documented no-arg / --write path exits on an empty tag -- which is the very
  # command the chart comments and the ingestor-multiarch CI error tell people
  # to run (Bugbot, #494).
  if command -v yq >/dev/null 2>&1 && [[ -f "$chart_values" ]]; then
    tag="$(yq -r '.images.ingestor.tag' "$chart_values")"
    [[ "$tag" == "null" ]] && tag=""
    if [[ -z "$tag" ]]; then
      tag="$(yq -r '.images.ingestor.channelTags.prod' "$chart_values")"
      [[ "$tag" == "null" ]] && tag=""
    fi
  else
    tag="$(read_ingestor_tag "$chart_values" || true)"
    if [[ -z "$tag" ]]; then
      tag="$(read_ingestor_prod_channel "$chart_values" || true)"
    fi
  fi
  if [[ -z "$tag" ]]; then
    echo "ERROR: could not determine the default ingestor tag from ${chart_values#$here/../}." >&2
    echo "       (neither images.ingestor.tag nor images.ingestor.channelTags.prod was" >&2
    echo "        readable: file missing, keys absent, or yq not" >&2
    echo "        installed and the yq-free parse found nothing.)" >&2
    echo "       Fix: pass TAG explicitly — scripts/resolve-ingestor-digest.sh <TAG> [--write] —" >&2
    echo "       or install yq. Refusing to fall back to a hardcoded tag." >&2
    exit 1
  fi
fi

ref="${repo}:${tag}"

# Fail fast, BEFORE any registry work: refusing after resolution wastes the
# round-trip and hides the reason behind network output.
if [[ "$write" == 1 ]]; then
  # THE ORDERING CEILING (backend#1528, tightened backend#3142). While ANY prod
  # edge still authenticates as the shared `edgeuser`, the ingestor it runs must
  # be a release that still HAS the edgeuser fallback. data-ingestors#468 removed
  # that fallback, so a prod pin refreshed past it authenticates as an account
  # that edge has not minted and ingestion fails there at Config().
  #
  # This helper resolves a CHANNEL FLOAT and knows nothing about that ceiling,
  # so following values.yaml's own "use the helper, never pin by hand" advice
  # silently produces the wrong answer while the boundary is still active. That
  # nearly shipped in client#490. Fail closed instead.
  #
  # The disarm requires TWO definite positives, both read from values.yaml so the
  # guard tracks real state rather than a hardcoded version:
  #
  #   1. serviceDbAccountsByEnv.prod is a definite `true` — the DB-identity path
  #      is baked on by default. Anything else (false, absent, unparseable) fails
  #      CLOSED: absence is not evidence the ceiling lifted (backend#1528).
  #
  #   2. NO ackDrift hold stands on the prod pin. The flag flipping to `true` only
  #      changed the chart DEFAULT — a fresh install mints tb_ingest and needs no
  #      fallback — but it does NOT migrate the durable population that stored the
  #      old value: an edge upgraded with plain `--reuse-values`, or carrying an
  #      operator-set serviceDbAccountsByEnv.prod: false, keeps the flag off, gets
  #      no DB_USER, and still authenticates as edgeuser (docs/SECURITY.md §8.10).
  #      The ackDrift block (backend#2673) is the chart's machine-readable record
  #      that the boundary is STILL active and the pin is parked in the safe set
  #      on purpose; while it stands, resolving the float here would pin PAST the
  #      ceiling and strand those edges (backend#3142). It lifts when the boundary
  #      is resolved and the block is deleted in the same change that advances the
  #      pin — see the ackDrift note in client/values.yaml. Keying the disarm on
  #      the flag alone read the default as if it were the fleet's state.
  #
  # INGESTOR_PIN_ALLOW_PRE_FLAG=1 overrides BOTH, for a target release you have
  # VERIFIED still carries the fallback.
  prod_flag="$(read_prod_service_db_accounts "$chart_values" || true)"
  ack_hold="$(read_prod_pin_ackdrift_line "$chart_values" || true)"
  if [[ "${INGESTOR_PIN_ALLOW_PRE_FLAG:-0}" != "1" ]]; then
    if [[ "$prod_flag" != "true" ]]; then
      if [[ -n "$prod_flag" ]]; then
        echo "ERROR: refusing to refresh the prod pin while serviceDbAccountsByEnv.prod is $prod_flag." >&2
      else
        echo "ERROR: refusing to refresh the prod pin: could not read serviceDbAccountsByEnv.prod" >&2
        echo "       from $chart_values, so the ordering ceiling below cannot be ruled out." >&2
      fi
      echo "       Prod authenticates as the shared edgeuser, so its ingestor must be a release" >&2
      echo "       that still carries the edgeuser fallback (data-ingestors#468 removed it)." >&2
      echo "       Resolving the channel float here can pin past that ceiling and break ingestion" >&2
      echo "       on every prod edge — client#490 nearly shipped exactly this." >&2
      echo "" >&2
      echo "       Do ONE of:" >&2
      echo "         1. Flip serviceDbAccountsByEnv.prod to true first (the #1528 S0 windowed" >&2
      echo "            drill), confirm jobs-manager mints tb_ingest and stamps the creds onto" >&2
      echo "            spawned Jobs, then re-run." >&2
      echo "         2. If you have VERIFIED the target release still has the fallback, re-run" >&2
      echo "            with INGESTOR_PIN_ALLOW_PRE_FLAG=1 and say so in the PR." >&2
      exit 1
    fi
    if [[ -n "$ack_hold" ]]; then
      echo "ERROR: refusing to refresh the prod pin: images.ingestor.ackDrift holds it behind" >&2
      echo "       the \"$ack_hold\" float ON PURPOSE (backend#2673)." >&2
      echo "       serviceDbAccountsByEnv.prod being true only flipped the chart DEFAULT: a fresh" >&2
      echo "       install mints tb_ingest and needs no fallback. It does NOT migrate the durable" >&2
      echo "       population that still authenticates as edgeuser — an edge upgraded with plain" >&2
      echo "       --reuse-values, or carrying an operator-set serviceDbAccountsByEnv.prod: false," >&2
      echo "       keeps the flag off and still needs the fallback (docs/SECURITY.md §8.10). The" >&2
      echo "       ackDrift hold is the chart's record that the data-ingestors#468 boundary is" >&2
      echo "       still active, so resolving the float here can pin PAST it and break ingestion" >&2
      echo "       on those edges at Config() (backend#3142)." >&2
      echo "" >&2
      echo "       Do ONE of:" >&2
      echo "         1. Once those edges have adopted serviceDbAccounts (or a prod-safe 0.8.x is" >&2
      echo "            cut), delete the images.ingestor.ackDrift block in the SAME change that" >&2
      echo "            advances the pin — values.yaml says so next to it — then re-run." >&2
      echo "         2. If you have VERIFIED the target release still has the fallback, re-run" >&2
      echo "            with INGESTOR_PIN_ALLOW_PRE_FLAG=1 and say so in the PR." >&2
      exit 1
    fi
  fi
fi

# Resolve the top-level (index) digest. Prefer buildx imagetools (prints the
# manifest-list/index digest directly); fall back to `docker manifest inspect`.
digest=""
if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
  # Capture, then slice with a here-string. `awk ... exit` closes the pipe
  # after ~3 lines, so under `set -o pipefail` (line 30) a SIGPIPE'd inspect
  # makes the substitution 141 and errexit kills the script before the
  # "could not resolve a digest" diagnostic below can run (backend#1778).
  imagetools_out="$(docker buildx imagetools inspect "$ref" 2>/dev/null || true)"
  digest="$(awk '/^Digest:/ {print $2; exit}' <<<"$imagetools_out")"
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
    echo "       Refusing to pin a single-arch digest as the chart's prod pin (client#186 / #160)." >&2
    echo "       helm-ci's ingestor-multiarch guard would reject this pin at CI time." >&2
    exit 1
  fi
  echo "WARNING: $resolved is not a linux/amd64 + linux/arm64 multi-arch index (saw: ${platforms:-none})." >&2
  echo "         Pinning an arch-specific digest breaks ingestion on the other arch (client#186)." >&2
fi

echo "${repo}@${digest}  (tag ${tag}; platforms: ${platforms:-unknown})"

if [[ "$write" == 1 ]]; then
  [[ -f "$chart_values" ]] || { echo "ERROR: $chart_values not found." >&2; exit 1; }
  # Patch `images.ingestor.prodDigest` in the chart's DEFAULT values.yaml.
  #
  # Keyed on the distinct `prodDigest:` name rather than a bare `digest:`:
  # values.yaml carries a `digest:` leaf for EVERY image (jobsManager,
  # podsMonitor, egressProxy, busybox, …), so a `digest:`-anchored sed would
  # rewrite the wrong image — or all of them. Assert the key occurs exactly once
  # before touching the file, so a future rename/duplication fails loudly here
  # instead of silently patching a sibling.
  matches="$(grep -c -E '^[[:space:]]*prodDigest:[[:space:]]*"' "$chart_values" || true)"
  if [[ "$matches" != "1" ]]; then
    echo "ERROR: expected exactly one 'prodDigest: \"…\"' line in ${chart_values#$here/../}, found ${matches}." >&2
    echo "       Refusing to patch: the prod pin's location is ambiguous." >&2
    echo "       Fix images.ingestor.prodDigest to a single quoted line and re-run." >&2
    exit 1
  fi
  tmp="$(mktemp)"
  sed -E "s|(^[[:space:]]*prodDigest:[[:space:]]*\").*(\")|\1${digest}\2|" "$chart_values" >"$tmp"
  mv "$tmp" "$chart_values"
  # Verify the sed actually landed: if the line has drifted from the expected
  # `prodDigest: "…"` format, sed matches nothing and silently leaves the file
  # unchanged. Confirm the intended digest is now present before reporting
  # success.
  if ! grep -q -E "^[[:space:]]*prodDigest:[[:space:]]*\"${digest}\"" "$chart_values"; then
    echo "ERROR: ${chart_values#$here/../} was not patched — no matching prodDigest line found." >&2
    echo "       Expected a line of the form:  prodDigest: \"${digest}\"" >&2
    echo "       Fix images.ingestor.prodDigest to that format and re-run." >&2
    exit 1
  fi
  echo "Wrote ${digest} to ${chart_values#$here/../} (images.ingestor.prodDigest)" >&2
  echo "NEXT: bump client/Chart.yaml (version + appVersion) — the chart only" >&2
  echo "      publishes on a version change, so an unbumped pin reaches no edge." >&2
fi
