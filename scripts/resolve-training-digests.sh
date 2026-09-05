#!/usr/bin/env bash
# resolve-training-digests.sh — resolve every training image's index digest AND
# the engine's own capability label, and (optionally) write both into the chart's
# `images.training` block. RFC-1246 P2 / RFC-0067 D8, backend#3156; the release
# train runs this on every tracebloc-engine prod promotion (release-train#151).
#
# WHY ONE SCRIPT WRITES BOTH KEYS. `images.training.digests` says WHICH engine
# bytes a prod edge runs; `images.training.capabilities` says what that engine can
# do, and client-runtime requests N>1 GPUs only when `ddp` is in it (RFC-0067 D8's
# skew guard). A capability typed beside a pin is a restated fact: it agrees with
# the pin on the day it is written and drifts the first time the pin moves. So
# the capability is DERIVED — read off the pinned GPU images' OCI label
# `io.tracebloc.engine.capabilities` (tracebloc-engine#857) — by the same step,
# from the same digests, and written in the same edit. The chart template refuses
# `capabilities` with an empty `digests` for the same reason.
#
# THREE REFUSALS, all fail-closed, none of them a warning:
#   * a GPU image whose config cannot be read (auth, rate limit, network, a
#     garbage-collected digest). UNREADABLE IS NOT EMPTY: an engine that declares
#     no label is a fact (capabilities ""), a label nobody could read is not.
#   * GPU images that DISAGREE on the label. One map, one engine build: two
#     answers mean the tag points at a half-promoted set, and pinning it would
#     let one task claim DDP while another cannot.
#   * a task with only one arch under the tag. RFC-1246 §P2: all task x arch
#     images exist, so a missing one is a promotion bug, not a choice.
#
# THE REPO LIST IS DERIVED, NOT TYPED. `tracebloc/client-<task>-<arch>` is
# enumerated from the registry namespace, so a task the engine adds appears
# here without an edit and one it retires stops being pinned. (The engine's task
# set lives in another repo; a copy here would be exactly the list this script
# exists not to keep.)
#
# Usage:
#   scripts/resolve-training-digests.sh                 # print the YAML block
#   scripts/resolve-training-digests.sh --write         # patch client/values.yaml
#   scripts/resolve-training-digests.sh --tag stg       # resolve another float
#   scripts/resolve-training-digests.sh --values FILE   # another values.yaml
#
# After --write, BUMP client/Chart.yaml (version + appVersion): the chart only
# publishes on a version change, so an unbumped refresh reaches no edge.
#
# TEST SEAMS (bats), banner-marked so a stubbed run can never pass as an audit:
#   TRAINING_REPOS_STUB    file, one repository name per line — replaces the
#                          registry listing.
#   TRAINING_RESOLVE_STUB  file of `key<0x1f>value` lines — replaces the registry:
#                            ns/repo:tag<0x1f>sha256:…        the float's index digest
#                            ns/repo@sha256:…<0x1f>caps=<v>   the pinned image's label
#                            ns/repo@sha256:…<0x1f>inspect=<file>  a captured
#                                 `imagetools inspect --format '{{json .Image}}'`
#                                 document, run through the REAL label extraction
#                          A pin with NO caps line is UNREADABLE (the refusal);
#                          `caps=` with an empty value is readable-and-unlabelled.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# curl_secure() carries the repo's TLS floor and timeout bounds (backend#1252);
# a bare curl here would drop both and fail check-style.sh rule 3.
# shellcheck source=scripts/lib/common.sh
. "$here/lib/common.sh"
chart_values="${CHART_VALUES:-$here/../client/values.yaml}"
namespace="${TRAINING_NAMESPACE:-tracebloc}"
tag="prod"
write=0
LABEL="io.tracebloc.engine.capabilities"
SEP="$(printf '\037')"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write) write=1; shift ;;
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --values) chart_values="${2:?--values needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

refuse() { echo "REFUSED: $*" >&2; exit 1; }

_tmout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

stubbed=0
if [[ -n "${TRAINING_REPOS_STUB:-}" || -n "${TRAINING_RESOLVE_STUB:-}" ]]; then
  stubbed=1
  echo "*** STUBBED RUN — registry replaced by TRAINING_REPOS_STUB / TRAINING_RESOLVE_STUB. NOT a real resolution. ***"
  [[ -n "${TRAINING_REPOS_STUB:-}" && -r "${TRAINING_REPOS_STUB}" ]] || refuse "TRAINING_REPOS_STUB is unset or unreadable while stubbing"
  [[ -n "${TRAINING_RESOLVE_STUB:-}" && -r "${TRAINING_RESOLVE_STUB}" ]] || refuse "TRAINING_RESOLVE_STUB is unset or unreadable while stubbing"
else
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required to read the registry listing and image configs" >&2; exit 2; }
  command -v docker >/dev/null 2>&1 || { echo "ERROR: docker (buildx) is required to resolve digests and read labels" >&2; exit 2; }
fi

# list_repos — every repository name in the namespace, one per line, or NOTHING
# and a non-zero status. ALL OR NOTHING (Bugbot, client#978): a failure on page 2
# used to leave page 1 on stdout, and a partial listing that looks complete is
# how `--write` pins a subset of the fleet and exits 0. Pages are accumulated
# and printed only once every one of them has been fetched and parsed.
list_repos() {
  if [[ "$stubbed" == 1 ]]; then
    grep -v '^[[:space:]]*$' "$TRAINING_REPOS_STUB" || true
    return 0
  fi
  local url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=100" page names="" more=""
  while [[ -n "$url" && "$url" != "null" ]]; do
    page="$(curl_secure -fsS "$url")" || { echo "ERROR: registry listing failed at $url" >&2; return 1; }
    more="$(jq -r '.results[].name' <<<"$page")" || { echo "ERROR: registry listing page is not the expected JSON: $url" >&2; return 1; }
    names+="${more}"$'\n'
    url="$(jq -r '.next' <<<"$page")" || { echo "ERROR: registry listing page is not the expected JSON: $url" >&2; return 1; }
  done
  printf '%s' "$names"
}

# resolve_index_digest <ns/repo:tag> — the index digest the float points at.
resolve_index_digest() {
  local ref="$1" d=""
  if [[ "$stubbed" == 1 ]]; then
    d="$(awk -F"$SEP" -v want="$ref" '$1 == want { print $2; exit }' "$TRAINING_RESOLVE_STUB")"
  else
    d="$(_tmout 30 docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  fi
  [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$d"
}

# read_capabilities <ns/repo> <digest> — the label's value ("" when the image is
# readable but unlabelled). Returns 1 when the config CANNOT be read, and the
# caller refuses: unreadable is not empty.
read_capabilities() {
  local repo="$1" digest="$2" ref="$1@$2" line="" raw="" n
  if [[ "$stubbed" == 1 ]]; then
    line="$(awk -F"$SEP" -v want="$ref" '$1 == want { print $2; exit }' "$TRAINING_RESOLVE_STUB")"
    case "$line" in
      caps=*)    printf '%s\n' "${line#caps=}"; return 0 ;;
      inspect=*) raw="$(cat -- "${line#inspect=}")" || return 1 ;;   # falls through to the real extraction
      *)         return 1 ;;
    esac
  else
    raw="$(_tmout 30 docker buildx imagetools inspect "$ref" --format '{{json .Image}}' 2>/dev/null)" || return 1
  fi
  [[ -n "$raw" ]] || return 1
  # A single-platform image is one config; an index is a platform -> config map.
  # Every platform under one digest must agree; disagreement inside ONE image is
  # reported as a distinct value so the caller's agreement check catches it.
  # buildx lists a provenance/SBOM attestation manifest as the platform
  # `unknown/unknown`, and its "config" carries no Labels -- so without this
  # filter every attested image reads as `<caps>|` and is refused as a
  # disagreement it does not have (client#978). Same filter as
  # check-digest-drift.sh and resolve-ingestor-digest.sh apply to `Platform:`.
  n="$(jq -r --arg l "$LABEL" '
        (if has("config") then [{key: "", value: .}] else to_entries end)
        | map(select((.key | startswith("unknown")) | not))
        | map(select((.value.os // "") != "unknown" and (.value.architecture // "") != "unknown"))
        | map((.value.config.Labels // {})[$l] // "") | unique | join("|")' <<<"$raw")" || return 1
  printf '%s\n' "$n"
}

# --- enumerate ---------------------------------------------------------------
listing="$(list_repos)" || refuse "the registry listing for '${namespace}' could not be fetched in full; a partial listing is not a fleet to pin."
repos="$(grep -E '^client-[a-z][a-z0-9_]*-(cpu|gpu)$' <<<"$listing" | sort -u || true)"
[[ -n "$repos" ]] || refuse "no training image repositories found under '${namespace}/client-<task>-<arch>' (the namespace moved, or the naming convention did). Nothing to pin."

tasks="$(sed -E 's/^client-(.*)-(cpu|gpu)$/\1/' <<<"$repos" | sort -u)"
for task in $tasks; do
  for arch in cpu gpu; do
    grep -qx "client-${task}-${arch}" <<<"$repos" \
      || refuse "task '${task}' has no '${arch}' image under the namespace. RFC-1246 P2: every task x arch image exists, so this is a promotion bug — not a set to pin half of."
  done
done

# --- resolve -----------------------------------------------------------------
declare -a digest_lines=()
declare -a caps_seen=()
for task in $tasks; do
  for arch in cpu gpu; do
    repo="${namespace}/client-${task}-${arch}"
    ref="${repo}:${tag}"
    if ! digest="$(resolve_index_digest "$ref")"; then
      refuse "could not resolve ${ref} to a canonical index digest (auth, rate limit, network, or the tag is not published). Not being able to look is not a pin."
    fi
    digest_lines+=("${task}${SEP}${arch}${SEP}${digest}")
    if [[ "$arch" == gpu ]]; then
      if ! caps="$(read_capabilities "$repo" "$digest")"; then
        refuse "the config of ${repo}@${digest} could not be read, so its '${LABEL}' label is UNKNOWN. Unreadable is not empty: refusing to write a capability nobody read."
      fi
      caps_seen+=("${task}${SEP}${caps}")
    fi
  done
done

distinct="$(printf '%s\n' "${caps_seen[@]}" | awk -F"$SEP" '{ print $2 }' | sort -u)"
if [[ "$(wc -l <<<"$distinct" | tr -d ' ')" != 1 ]]; then
  {
    echo "REFUSED: the pinned GPU images DISAGREE on '${LABEL}' — one map must describe one engine build:"
    printf '%s\n' "${caps_seen[@]}" | awk -F"$SEP" '{ printf "  %-40s %s\n", $1, ($2 == "" ? "(no label)" : $2) }'
    echo "  The tag '${tag}' points at a half-promoted set. Re-run after the promotion completes."
  } >&2
  exit 1
fi
capabilities="$distinct"
if [[ "$capabilities" == *"|"* ]]; then
  refuse "a single GPU image carries different '${LABEL}' values across its platforms (${capabilities}); refusing to pick one."
fi
if [[ -n "$capabilities" && ! "$capabilities" =~ ^[a-z][a-z0-9_-]*(,[a-z][a-z0-9_-]*)*$ ]]; then
  refuse "the '${LABEL}' label value '${capabilities}' is not a comma-separated token list; refusing to write it."
fi

# --- render ------------------------------------------------------------------
# `pinned` is preserved from the current file: it is the operator/auto gate, not
# something a re-resolution has an opinion about.
current_pinned='""'
if [[ -r "$chart_values" ]]; then
  p="$(awk '
    /^images:[[:space:]]*$/ { in_images = 1; next }
    /^[^[:space:]#]/        { in_images = 0; in_tr = 0 }
    in_images && /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { in_tr = ($0 ~ /^  training:[[:space:]]*$/) ? 1 : 0; next }
    in_tr && /^    pinned:[[:space:]]*/ { v = $0; sub(/^    pinned:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v); print v; exit }
  ' "$chart_values")"
  [[ -n "$p" ]] && current_pinned="$p"
fi

render_block() {
  echo "  training:"
  echo "    pinned: ${current_pinned}"
  echo "    digests:"
  local last=""
  while IFS="$SEP" read -r task arch digest; do
    if [[ "$task" != "$last" ]]; then echo "      ${task}:"; last="$task"; fi
    echo "        ${arch}: \"${digest}\""
  done < <(printf '%s\n' "${digest_lines[@]}")
  echo "    capabilities: \"${capabilities}\""
}

block="$(render_block)"
n_tasks="$(wc -l <<<"$tasks" | tr -d ' ')"
echo "resolved ${n_tasks} task(s) x 2 arch(es) under ${namespace}/client-*:${tag}; capabilities=\"${capabilities}\"$( [[ -z "$capabilities" ]] && printf ' (the pinned engine declares none — the runtime stays at one GPU)')"
if [[ "$stubbed" == 1 ]]; then echo "*** STUBBED — the digests above came from a test seam, not a registry. ***"; fi

if [[ "$write" == 0 ]]; then
  echo
  echo "images:"
  printf '%s\n' "$block"
  exit 0
fi

# --- write -------------------------------------------------------------------
[[ -f "$chart_values" ]] || refuse "--write: ${chart_values} does not exist"
# images_training_block <file> -- the current `  training:` subtree INSIDE images:
# (networkPolicy.training and any other 2-space `training:` do not count -- Bugbot,
# client#978). Empty output means the chart has no such block.
images_training_block() {
  awk '
    /^images:[[:space:]]*$/ { in_images = 1; next }
    /^[^[:space:]#]/        { in_images = 0; in_tr = 0 }
    in_images && /^  training:[[:space:]]*$/ { in_tr = 1; print; next }
    in_images && /^  [A-Za-z_]/ { in_tr = 0 }
    # A blank line belongs to the subtree only if more 4-space content follows;
    # a blank that ends the block is a separator of the FILE, not of the block.
    in_tr && /^[[:space:]]*$/ { held = held $0 "\n"; next }
    in_tr && /^    /          { printf "%s", held; held = ""; print; next }
    { held = "" }
  ' "$1"
}
[[ -n "$(images_training_block "$chart_values")" ]] || refuse "--write: ${chart_values} has no 'images.training' block to replace (chart predates backend#3156)"

tmp="$(mktemp)"; blockfile="$(mktemp)"
printf '%s\n' "$block" > "$blockfile"
# The block travels through a FILE, not `awk -v`: BSD awk (macOS) rejects a -v
# value that contains a newline ("newline in string"), and the block is many.
awk -v blockfile="$blockfile" '
  /^images:[[:space:]]*$/ { in_images = 1; print; next }
  # A top-level key ends the subtree too: flush the held blank FIRST, or the
  # separator before the next section is eaten when training: is the last key
  # under images: (Bugbot, client#978).
  /^[^[:space:]#]/        { if (skipping) { printf "%s", held; held = "" }; in_images = 0; skipping = 0 }
  in_images && /^  training:[[:space:]]*$/ {
    while ((getline l < blockfile) > 0) print l
    close(blockfile)
    skipping = 1; next
  }
  skipping {
    # The subtree is every line indented 4+ spaces that follows. A blank line is
    # held: dropped if more subtree follows, kept if it was the trailing
    # separator (Saqlain, client#978 -- --write must not eat the blank line of the file).
    if ($0 ~ /^    /)           { held = ""; next }
    if ($0 ~ /^[[:space:]]*$/)  { held = held $0 "\n"; next }
    printf "%s", held; held = ""; skipping = 0
  }
  { print }
' "$chart_values" > "$tmp"
mv "$tmp" "$chart_values"; rm -f "$blockfile"
# READ BACK before claiming success (Bugbot, client#978): the block now in the
# file must be exactly the block that was rendered, or the write did not land.
written="$(images_training_block "$chart_values" | sed -e 's/[[:space:]]*$//')"
if [[ "$written" != "$(printf '%s\n' "$block" | sed -e 's/[[:space:]]*$//')" ]]; then
  echo "ERROR: --write finished but ${chart_values} does not carry the rendered images.training block; refusing to report success." >&2
  exit 1
fi
echo "wrote images.training into ${chart_values} (read back and verified). Now bump client/Chart.yaml (version + appVersion) so the pins reach the fleet."
