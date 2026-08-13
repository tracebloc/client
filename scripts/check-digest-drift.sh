#!/usr/bin/env bash
# check-digest-drift.sh — watch every mutable label that points at a pinned digest.
#
# WHY THIS EXISTS (backend#1853)
# -----------------------------
# On 2026-08-12 the ingestor's `channelTags.prod: "0.8"` float moved from 0.8.4
# to 0.8.8, and 0.8.8 dropped the legacy `edgeuser` DB_USER fallback. Default
# prod edges were protected only because `prodDigest` pins 0.8.2. Nothing
# noticed the move; it was found by a manual sweep.
#
# THE DIAGNOSIS THAT SHAPED THIS SCRIPT (Saqlain, on backend#1853):
#
#   "The disease is a moving label pointing at an immutable trust decision, with
#    no watcher on the label. Anything about the build could have been the thing
#    that changed -- the fallback just got there first."
#
# So this script deliberately makes NO assertion about the contents of a build.
# It does not know or care what `DB_USER` is. It asks one property-agnostic
# question, for every pinned image in the chart:
#
#     does the float still resolve to the digest we decided to trust?
#
# If it does not, that is the alarm, and a human re-verifies. A check that
# instead asserted "the fallback is still present" would go green the next time
# something ELSE moves -- which is the failure this script exists to prevent, not
# a variant of it.
#
# WHERE THE TRUSTED VERSIONS ARE REGISTERED: in the chart, as the `digest:` /
# `prodDigest:` fields of client/values.yaml. There is no second list to keep in
# sync -- the pin IS the registration. Adding a pin automatically enrols it here.
#
# READ-ONLY. Never writes, never publishes. To advance a pin, use
# scripts/resolve-ingestor-digest.sh --write, which carries its own ceiling
# guard (backend#1528).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart_values="${CHART_VALUES:-$here/../client/values.yaml}"

FINDINGS=0
CHECKED=0
PINS=0

if [[ ! -r "$chart_values" ]]; then
  echo "ERROR: cannot read $chart_values" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Readers. Same scoping discipline as resolve-ingestor-digest.sh: a leaf is only
# matched inside its own `images: -> <key>:` block, so a sibling image's `tag:`
# or `digest:` can never be picked up by mistake. Pure awk, bash-3.2/macOS-safe.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Registry resolution. Same two-step as resolve-ingestor-digest.sh: buildx
# imagetools prints the manifest-list/index digest directly; docker manifest
# inspect is the fallback.
#
# The capture-then-slice via here-string is NOT stylistic. `inspect | awk ...
# exit` closes the pipe early, and under `set -o pipefail` a SIGPIPE'd producer
# makes the substitution 141, which killed a script before its own diagnostic
# could run (backend#1778). Capture first, slice after.
# ---------------------------------------------------------------------------
# DRIFT_RESOLVE_STUB is a TEST SEAM, and the banner below exists so it can never
# be mistaken for a real audit. It points at a file of `ref<0x1f>digest` lines and
# replaces the registry entirely -- the suite needs to assert classification
# (ok / DRIFT / UNRESOLVED / UNWATCHABLE) without a network, and the parsing is
# where this script's two real bugs were. A stubbed run prints STUBBED on every
# line and in the summary, so a log cannot look like evidence it is not.
resolve_index_digest() {
  local ref="$1" out="" d=""
  if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
    [[ -r "$DRIFT_RESOLVE_STUB" ]] || { echo "ERROR: DRIFT_RESOLVE_STUB is set but unreadable: $DRIFT_RESOLVE_STUB" >&2; exit 2; }
    d="$(awk -F"$(printf '\037')" -v want="$ref" '$1 == want { print $2; exit }' "$DRIFT_RESOLVE_STUB")"
    [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$d"
    return 0
  fi
  if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
    out="$(docker buildx imagetools inspect "$ref" 2>/dev/null || true)"
    d="$(awk '/^Digest:/ {print $2; exit}' <<<"$out")"
  fi
  if [[ -z "$d" ]]; then
    out="$(docker manifest inspect --verbose "$ref" 2>/dev/null || true)"
    d="$(grep -m1 '"Ref"' <<<"$out" | sed -E 's/.*@(sha256:[a-f0-9]{64}).*/\1/')"
  fi
  [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$d"
}

# discover_pins <file>
#
# PIN-DRIVEN, and deliberately not scoped to `images:`. My first version walked
# `images:` and read each key's tag/digest, which silently watched 1 of the 3
# pins in this file: squid's pin lives OUTSIDE images:, and mysqlClient has no
# `repository:` leaf at all, so an "empty means skip" rule dropped it without a
# word. A watcher that quietly covers a third of its subject is the failure this
# script exists to catch.
#
# So: find every non-empty digest pin ANYWHERE, then resolve its block's
# repository and float. Enrolment is automatic and cannot be missed -- a pin is
# either watched or REPORTED, never skipped.
#
# Emits one TSV record per pin: path <TAB> repository <TAB> float <TAB> pin
# with an empty field where the file does not say.
discover_pins() {
  awk -v SEP="$(printf '\037')" '
    function trim(v) {
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v); gsub(/^\047|\047$/, "", v)
      return v
    }
    # Track the innermost 0-space and 2-space keys so a pin can be named.
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      top = $0; sub(/:.*$/, "", top); mid = ""; blk_repo = ""; blk_tag = ""
    }
    /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
      mid = $0; sub(/^  /, "", mid); sub(/:[[:space:]]*$/, "", mid)
      blk_repo = ""; blk_tag = ""; ch_prod = ""
    }
    # Leaves of the current block. Only the FIRST of each kind, so a commented
    # example further down cannot overwrite the live value.
    /^    repository:[[:space:]]*/ { if (blk_repo == "") { v = $0; sub(/^    repository:[[:space:]]*/, "", v); blk_repo = trim(v) } }
    /^    tag:[[:space:]]*/        { if (blk_tag  == "") { v = $0; sub(/^    tag:[[:space:]]*/, "", v);        blk_tag  = trim(v) } }
    /^      prod:[[:space:]]*/     { if (ch_prod  == "") { v = $0; sub(/^      prod:[[:space:]]*/, "", v);     ch_prod  = trim(v) } }
    # A pin. prodDigest pairs with channelTags.prod; digest pairs with tag.
    /^    (digest|prodDigest):[[:space:]]*"sha256:/ {
      kind = $0; sub(/^    /, "", kind); sub(/:.*$/, "", kind)
      v = $0; sub(/^    (digest|prodDigest):[[:space:]]*/, "", v); pin = trim(v)
      flt = (kind == "prodDigest") ? ch_prod : blk_tag
      name = (mid == "") ? top : top "." mid
      printf "%s%s%s%s%s%s%s\n", name, SEP, blk_repo, SEP, flt, SEP, pin
    }
  ' "$1"
}

report_drift() {  # <path> <ref> <pinned> <resolved>
  FINDINGS=$((FINDINGS + 1))
  cat <<EOF

DRIFT: $1
  the label          $2
  now resolves to    $4
  but the pin says   $3

  The trusted build and the build the label points at are no longer the same.
  Nothing here says the new build is bad -- only that nobody has looked at it.
  A human must re-verify before the pin moves.

  Deliberately property-agnostic (backend#1853). The last time this happened the
  thing that moved was a DB_USER fallback; asserting THAT specifically would go
  green the next time something else moves, which is the failure this watches
  for rather than a variant of it.
EOF
}

report_unwatchable() {  # <path> <pin> <why>
  FINDINGS=$((FINDINGS + 1))
  cat <<EOF

UNWATCHABLE: $1 is pinned to $2
  but $3

  A pin records a trust decision. If the label it is meant to track cannot be
  determined from the chart, nothing can tell you when that decision goes stale
  -- which is the same blind spot as having no watcher at all, just quieter.

  Fix by declaring the repository/tag in values.yaml next to the pin, or by
  recording there why this pin needs no watcher.
EOF
}

if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
  echo "*** STUBBED RUN — registry replaced by $DRIFT_RESOLVE_STUB. NOT a real audit. ***"
fi
echo "Watching every mutable label that points at a pinned digest."
echo "Registry of trusted versions: ${chart_values#"$here"/../}"
echo

while IFS="$(printf '\037')" read -r path repo flt pin; do
  [[ -n "${pin:-}" ]] || continue
  PINS=$((PINS + 1))

  if [[ -z "${repo:-}" ]]; then
    report_unwatchable "$path" "$pin" "the block declares no \`repository:\`, so there is no image to resolve."
    continue
  fi
  if [[ -z "${flt:-}" ]]; then
    report_unwatchable "$path" "$pin" "the block declares no tag (or channel) to resolve against."
    continue
  fi

  CHECKED=$((CHECKED + 1))
  ref="${repo}:${flt}"
  if ! resolved="$(resolve_index_digest "$ref")"; then
    # Fail CLOSED. An unresolvable label is not evidence of agreement, and
    # "green because it could not look" is the class this repo keeps
    # rediscovering (backend#1729).
    FINDINGS=$((FINDINGS + 1))
    printf '\nUNRESOLVED: %s could not be resolved (registry auth, rate limit, network?).\n' "$ref"
    printf '  Reporting rather than passing: not being able to look is not the same as\n'
    printf '  looking and finding agreement.\n'
    continue
  fi

  if [[ "$resolved" == "$pin" ]]; then
    printf 'ok    %-46s %s\n' "$ref" "${pin:0:19}…"
  else
    report_drift "$path" "$ref" "$pin" "$resolved"
  fi
done <<EOF
$(discover_pins "$chart_values")
EOF

printf '\n%s\n' "-----"
# Guard on PINS DISCOVERED, not on pins checked. Counting only what got as far
# as a registry call would let a reader that stopped matching the file report
# "no drift" -- an audit that examined nothing must never look like a pass.
if [[ "$PINS" -eq 0 ]]; then
  echo "ERROR: found no digest pins at all in ${chart_values#"$here"/../}."
  echo "       This chart pins images by digest as a matter of policy, so zero pins"
  echo "       means the reader stopped matching the file, not that there is nothing"
  echo "       to watch. Refusing to report success on an audit that examined nothing."
  exit 2
fi
if [[ "$FINDINGS" -eq 0 ]]; then
  echo "no drift: $CHECKED of $PINS pinned label(s) checked, all still resolve to their trusted digest."
  if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
    echo "  (STUBBED — proves nothing about the real registry.)"
  fi
  exit 0
fi
echo "$FINDINGS finding(s): $PINS pin(s) found, $CHECKED resolvable and compared."
echo
echo "To advance a pin deliberately, use scripts/resolve-ingestor-digest.sh --write"
echo "(it carries the ordering ceiling from backend#1528) and bump client/Chart.yaml"
echo "-- the chart only publishes on a version change, so an unbumped refresh"
echo "reaches no edge."
exit 1
