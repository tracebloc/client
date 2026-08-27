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
# ONE DELIBERATE EXCEPTION: ACKNOWLEDGED DRIFT (backend#2673). A pin can be held
# behind its float ON PURPOSE -- the ingestor prod pin trails channelTags.prod
# because the float has crossed a compatibility boundary while prod cannot yet
# take it (docs/SECURITY.md §4.1.1). For such a pin the float-vs-pin divergence is
# EXPECTED and reds nothing; without this the alarm fires every night forever,
# trains everyone to ignore it, and masks a NEW drift on some other pin behind the
# standing red (the backend#2386 failure mode). The exception is NOT a blanket
# mute: it is DECLARED IN THE CHART (an `ackDrift:` block next to the pin, behind
# CODEOWNERS review), it is a CLASS not a digest (the float may roam any patch on
# its line without re-alarming), it LAPSES if the float changes line, and the pin
# itself is STILL re-verified to resolve to a healthy multi-arch index every run.
# Any other pin drifting, or the acknowledged pin ceasing to resolve, still reds.
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
ACKNOWLEDGED=0

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
# be mistaken for a real audit. It points at a file of `ref<0x1f>value` lines and
# replaces the registry entirely -- the suite needs to assert classification
# (ok / DRIFT / UNRESOLVED / UNWATCHABLE / ACKNOWLEDGED) without a network, and the
# parsing is where this script's real bugs were. Two line shapes share the file:
# a `repo:tag<0x1f>digest` line answers resolve_index_digest (where the float
# points now), and a `repo@digest<0x1f>platform,platform` line answers
# pin_platforms (whether the pin is a healthy multi-arch index). A stubbed run
# prints STUBBED on every line and in the summary, so a log cannot look like
# evidence it is not.
# _tmout <seconds> <cmd...> — bound a registry/daemon call so a wedged docker or
# stuck registry fails closed (non-zero exit -> UNRESOLVED) rather than hanging the
# daily job (Bugbot). timeout on Linux, gtimeout on macOS; unbounded only if
# neither exists (the CI runner where the daily job runs has timeout).
_tmout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

resolve_index_digest() {
  local ref="$1" out="" d=""
  if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
    [[ -r "$DRIFT_RESOLVE_STUB" ]] || { echo "ERROR: DRIFT_RESOLVE_STUB is set but unreadable: $DRIFT_RESOLVE_STUB" >&2; exit 2; }
    d="$(awk -F"$(printf '\037')" -v want="$ref" '$1 == want { print $2; exit }' "$DRIFT_RESOLVE_STUB")"
    [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$d"
    return 0
  fi
  if _tmout 30 docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
    out="$(_tmout 30 docker buildx imagetools inspect "$ref" 2>/dev/null || true)"
    d="$(awk '/^Digest:/ {print $2; exit}' <<<"$out")"
  fi
  if [[ -z "$d" ]]; then
    out="$(_tmout 30 docker manifest inspect --verbose "$ref" 2>/dev/null || true)"
    d="$(grep -m1 '"Ref"' <<<"$out" | sed -E 's/.*@(sha256:[a-f0-9]{64}).*/\1/')"
  fi
  [[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$d"
}

# pin_platforms <repo> <digest> — the platform set of the index a pin points AT
# (backend#2673). resolve_index_digest asks "where does the float point now?";
# this asks "is the PIN itself still a healthy, reproducible multi-arch image?",
# by inspecting repo@digest exactly as resolve-ingestor-digest.sh does. Prints a
# space-separated platform list, or NOTHING when the pin does not resolve at all
# (auth, rate limit, network, or a garbage-collected digest) — an empty result
# is the caller's signal that the pin ceased to resolve.
#
# Test seam: under DRIFT_RESOLVE_STUB a `repo@digest` line maps to a
# comma-separated platform list (e.g. `linux/amd64,linux/arm64`); an absent line
# means "does not resolve", mirroring the real path.
pin_platforms() {
  # Separate declarations on purpose: a single `local a=$1 b="$a…"` expands the
  # later reference before the earlier assignment is visible, so under the
  # `set -u` above `b` sees an UNBOUND `a` and the subshell dies -- which read as
  # the pin failing to resolve. Assign, then compose.
  local repo="$1" digest="$2"
  local ref="${repo}@${digest}" out=""
  if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
    [[ -r "$DRIFT_RESOLVE_STUB" ]] || { echo "ERROR: DRIFT_RESOLVE_STUB is set but unreadable: $DRIFT_RESOLVE_STUB" >&2; exit 2; }
    awk -F"$(printf '\037')" -v want="$ref" '$1 == want { print $2; exit }' "$DRIFT_RESOLVE_STUB" | tr ',' ' '
    return 0
  fi
  out="$(_tmout 30 docker buildx imagetools inspect "$ref" 2>/dev/null || true)"
  awk '/Platform:/ {print $2}' <<<"$out" | grep -v '^unknown' | sort -u | tr '\n' ' '
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
      ack_line = ""; ack_reason = ""; in_ack = 0
    }
    /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
      mid = $0; sub(/^  /, "", mid); sub(/:[[:space:]]*$/, "", mid)
      blk_repo = ""; blk_tag = ""; ch_prod = ""
      ack_line = ""; ack_reason = ""; in_ack = 0
    }
    # A 4-space BARE key (no inline value): channelTags:, ackDrift:, … . Arm the
    # acknowledged-drift scope only inside ackDrift:, disarm on any other bare
    # 4-space key. repository:/tag:/prodDigest: carry inline values so they never
    # match here. (backend#2673)
    /^    [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
      in_ack = ($0 ~ /^    ackDrift:[[:space:]]*$/) ? 1 : 0
    }
    # Leaves of the current block. Only the FIRST of each kind, so a commented
    # example further down cannot overwrite the live value.
    /^    repository:[[:space:]]*/ { if (blk_repo == "") { v = $0; sub(/^    repository:[[:space:]]*/, "", v); blk_repo = trim(v) } }
    /^    tag:[[:space:]]*/        { if (blk_tag  == "") { v = $0; sub(/^    tag:[[:space:]]*/, "", v);        blk_tag  = trim(v) } }
    /^      prod:[[:space:]]*/     { if (ch_prod  == "") { v = $0; sub(/^      prod:[[:space:]]*/, "", v);     ch_prod  = trim(v) } }
    # ackDrift leaves (backend#2673). Only inside ackDrift:, only the first of
    # each. `line` binds the acknowledgement to the channel float it was reasoned
    # about; `reason` is the human justification, surfaced verbatim in the
    # ACKNOWLEDGED report. Extract reason from between its quotes rather than the
    # trim()+comment-strip path: it is free text and legitimately contains `#`
    # (issue refs) and punctuation a comment-stripper would eat.
    /^      line:[[:space:]]*/    { if (in_ack && ack_line   == "") { v = $0; sub(/^      line:[[:space:]]*/, "", v); ack_line = trim(v) } }
    /^      reason:[[:space:]]*/  { if (in_ack && ack_reason == "") { v = $0; if (match(v, /"[^"]*"/)) { ack_reason = substr(v, RSTART + 1, RLENGTH - 2) } else { sub(/^      reason:[[:space:]]*/, "", v); ack_reason = trim(v) } } }
    # A pin. prodDigest pairs with channelTags.prod; digest pairs with tag.
    #
    # Quote- and indent-agnostic on purpose (Bugbot, client#697). The old pattern
    # demanded a DOUBLE quote at EXACTLY four-space indent, so a single-quoted or
    # more-deeply-nested pin was dropped in total silence -- and the PINS==0 guard
    # below cannot catch that while any one conforming pin remains, so a `no drift`
    # pass would print with a pin unwatched. Detect the pin however it is written.
    # A canonical four-space pin pairs with the block repo/float as before; a pin
    # at any other depth is emitted with no repo/float, so the loop REPORTS it
    # UNWATCHABLE rather than skipping it -- watched or reported, never skipped.
    # (No apostrophes in these comments: the awk program is single-quoted.)
    /^[[:space:]]*(digest|prodDigest):[[:space:]]*["\047]?sha256:[a-f0-9]/ {
      kind = $0; sub(/^[[:space:]]*/, "", kind); sub(/:.*$/, "", kind)
      v = $0; sub(/^[[:space:]]*(digest|prodDigest):[[:space:]]*/, "", v); pin = trim(v)
      if ($0 ~ /^    (digest|prodDigest):/) {
        flt = (kind == "prodDigest") ? ch_prod : blk_tag
        name = (mid == "") ? top : top "." mid
        # Six fields: path, repo, float, pin, ackLine, ackReason. The ack pair is
        # empty for every pin that declares no ackDrift block (backend#2673).
        printf "%s%s%s%s%s%s%s%s%s%s%s\n", name, SEP, blk_repo, SEP, flt, SEP, pin, SEP, ack_line, SEP, ack_reason
      } else {
        # Off the canonical structure: name it as best we can, emit empty
        # repo+float (and empty ack pair) so the main loop reports UNWATCHABLE
        # instead of dropping.
        name = (mid != "") ? top "." mid : (top != "" ? top : "?")
        printf "%s%s%s%s%s%s%s%s%s%s%s\n", name, SEP, "", SEP, "", SEP, pin, SEP, "", SEP, ""
      }
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

# --- ACKNOWLEDGED, EXPECTED DRIFT (backend#2673) ---------------------------
# A pin may be DELIBERATELY held behind its float (the ingestor prod pin trails
# channelTags.prod on purpose -- docs/SECURITY.md §4.1.1). Such a pin declares an
# `ackDrift:` block in values.yaml. When it drifts we do NOT red -- but neither
# do we pass silently: the acknowledgement is CONDITIONAL, and these functions
# encode the conditions. report_acknowledged is the only green outcome; the other
# two are findings, because an acknowledgement whose preconditions broke is not
# an acknowledgement.

report_acknowledged() {  # <path> <ref> <pinned> <resolved> <reason> <platforms>
  ACKNOWLEDGED=$((ACKNOWLEDGED + 1))
  cat <<EOF

ACKNOWLEDGED: $1
  the label          $2
  now resolves to    $4
  but the pin says   $3

  This divergence is EXPECTED and acknowledged in the chart (backend#2673):
    $5
  The pin itself was re-verified against the registry and is intact: it still
  resolves to a multi-arch index ($6). The float roaming away from a deliberately
  held-back pin is the acknowledged condition, not a finding.

  Acknowledged for THIS pin only, and only while its channel float is unchanged.
  Any OTHER pin drifting, or this pin ceasing to resolve or going single-arch,
  still reds this watch. Boundary and lift conditions: docs/SECURITY.md §4.1.1.
EOF
}

report_ack_lapsed() {  # <path> <ref> <pinned> <resolved> <ack_line> <float>
  FINDINGS=$((FINDINGS + 1))
  cat <<EOF

DRIFT (acknowledgement lapsed): $1
  the label          $2
  now resolves to    $4
  but the pin says   $3

  The chart acknowledges this pin trailing its "$5" float, but the float now
  tracks "$6". The acknowledgement was reasoned about one specific line and its
  compatibility boundary (docs/SECURITY.md §4.1.1); a different line is a
  different boundary that nobody has re-derived. Red until a human re-verifies
  the boundary for "$6" and updates images.ingestor.ackDrift.line to match (or
  corrects the float). Not something this watcher may wave through on its own.
EOF
}

report_ack_pin_unhealthy() {  # <path> <ref> <pinned> <why>
  FINDINGS=$((FINDINGS + 1))
  cat <<EOF

DRIFT (acknowledged pin no longer healthy): $1
  the label          $2
  the pin says       $3
  but $4

  The float moving off this pin is acknowledged (backend#2673) -- but ONLY while
  the pin itself stays a valid, reproducible multi-arch image, which is the whole
  reason a prod edge pins a digest. It no longer is. This is a real finding: the
  reproducibility guarantee the pin exists for is void, independent of the
  acknowledged float movement. See docs/SECURITY.md §4.1.1.
EOF
}

if [[ -n "${DRIFT_RESOLVE_STUB:-}" ]]; then
  echo "*** STUBBED RUN — registry replaced by $DRIFT_RESOLVE_STUB. NOT a real audit. ***"
fi
echo "Watching every mutable label that points at a pinned digest."
echo "Registry of trusted versions: ${chart_values#"$here"/../}"
echo

while IFS="$(printf '\037')" read -r path repo flt pin ack_line ack_reason; do
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
  elif [[ -z "${ack_line:-}" ]]; then
    # The common case: the float moved off a pin that was NOT deliberately held
    # back. A real finding.
    report_drift "$path" "$ref" "$pin" "$resolved"
  elif [[ "$ack_line" != "$flt" ]]; then
    # Acknowledged, but for a DIFFERENT float line than the chart now tracks.
    # The acknowledgement has lapsed -- red until the boundary is re-derived.
    report_ack_lapsed "$path" "$ref" "$pin" "$resolved" "$ack_line" "$flt"
  else
    # Acknowledged expected drift (backend#2673). The float legitimately roams
    # away from a pin held back on purpose -- but the acknowledgement is
    # CONDITIONAL on the pin itself still being a healthy, reproducible image.
    # Re-verify that here; do not wave it through on the ack alone.
    plats="$(pin_platforms "$repo" "$pin")"
    if [[ -z "$plats" ]]; then
      # Fail CLOSED, and do not over-attribute: an empty platform set means the
      # pin could not be CONFIRMED healthy, which includes causes that are not
      # "the digest is gone" (buildx absent, auth, rate limit, network).
      report_ack_pin_unhealthy "$path" "$ref" "$pin" \
        "its multi-arch index could not be confirmed (registry auth, rate limit, network, docker buildx unavailable, or a garbage-collected digest)."
    elif ! { grep -q 'linux/amd64' <<<"$plats" && grep -q 'linux/arm64' <<<"$plats"; }; then
      report_ack_pin_unhealthy "$path" "$ref" "$pin" \
        "it is not a linux/amd64 + linux/arm64 multi-arch index (saw: ${plats% }); pinning a single-arch digest breaks ingestion on the other arch (client#186)."
    else
      report_acknowledged "$path" "$ref" "$pin" "$resolved" "$ack_reason" "${plats% }"
    fi
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
  if [[ "$ACKNOWLEDGED" -gt 0 ]]; then
    # Not "all resolve to their trusted digest" -- some deliberately do not, and
    # saying so keeps the acknowledged pins visible rather than folding them into
    # a flat "no drift" that hides how many pins are intentionally held back.
    echo "no unexpected drift: $CHECKED of $PINS pinned label(s) checked."
    echo "  $((CHECKED - ACKNOWLEDGED)) resolve to their trusted digest; $ACKNOWLEDGED acknowledged as"
    echo "  expected drift and re-verified healthy (backend#2673 / docs/SECURITY.md §4.1.1)."
  else
    echo "no drift: $CHECKED of $PINS pinned label(s) checked, all still resolve to their trusted digest."
  fi
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
