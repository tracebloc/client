#!/usr/bin/env bash
#
#  publish-helm-index.sh — add the just-built charts to the helm index while
#  preserving every existing version's real `created` timestamp.
#
#  WHY THIS IS NOT `helm repo index .`. The release job checks out gh-pages,
#  which already holds EVERY historical .tgz. `helm repo index .` over that
#  directory regenerates the index from scratch and stamps `created` to NOW for
#  every chart it finds — and `--merge index.yaml` does not save it: the merge
#  only ADDS versions the freshly-generated index lacks, and it lacks none,
#  because it just scanned them all. So every entry's `created` collapsed to the
#  release instant on every publish, which BLINDED the edge-chart-staleness
#  monitor: it measures how long a fix has been available from `created`, and if
#  every version looks published "just now", nothing is ever seen as stale
#  during normal release cadence (backend#3281, surfaced by backend#3261).
#
#  THE FIX: index ONLY the newly-built charts (an isolated directory), then merge
#  that into the existing index. helm regenerates `created` for the new versions
#  alone — which is correct, they ARE new — and `--merge` carries every existing
#  entry across untouched, keeping its real publish time on the wire.
#
#  TRADE-OFF, stated so it is a choice and not an accident: this trusts the prior
#  index.yaml as the complete record of historical charts, rather than
#  re-deriving it from the .tgz on gh-pages the way `helm repo index .` did. That
#  re-derivation is exactly what re-stamped `created`, so it is what we are giving
#  up on purpose. index.yaml and its .tgz are committed together and stay in sync,
#  so the only thing lost is self-healing a .tgz that is on disk but absent from
#  the index — a state this pipeline never produces.
#
#  ONE RESIDUAL `created` FLOAT, since this file is about `created` fidelity: a
#  workflow RE-RUN of the same release re-stamps just THAT version's `created` to
#  the re-run instant (helm regenerates it for the charts it indexes; every other
#  entry is carried untouched by --merge). Harmless — versions are immutable and
#  the version-bump gate makes a same-version re-publish rare — but it is the one
#  timestamp this approach does not pin.
#
#  Usage:
#    NEW_CHARTS_DIR=<dir with ONLY the just-built .tgz> \
#    REPO_URL=<https://owner.github.io/repo> \
#    [MERGE_INDEX=<existing index.yaml; unset/absent => first publish>] \
#    [OUT_INDEX=<where to write the merged index; default index.yaml>] \
#      bash scripts/publish-helm-index.sh
#
set -euo pipefail

# ::error:: goes to STDOUT, not stderr: Actions parses workflow commands from
# stdout only, so an ::error:: on stderr fails the step with no annotation
# (Bugbot, client#497).
fail() { echo "::error::$1"; exit 1; }

NEW_CHARTS_DIR="${NEW_CHARTS_DIR:-}"
REPO_URL="${REPO_URL:-}"
MERGE_INDEX="${MERGE_INDEX:-}"
OUT_INDEX="${OUT_INDEX:-index.yaml}"

command -v helm >/dev/null 2>&1 || fail "publish-helm-index: helm is not on PATH — cannot build the index."
[ -n "$NEW_CHARTS_DIR" ] || fail "publish-helm-index: NEW_CHARTS_DIR is not set."
[ -d "$NEW_CHARTS_DIR" ] || fail "publish-helm-index: NEW_CHARTS_DIR (${NEW_CHARTS_DIR}) is not a directory."
[ -n "$REPO_URL" ] || fail "publish-helm-index: REPO_URL is not set."

# There MUST be at least one new chart to index. A release run that reached this
# step with nothing to publish is a packaging bug upstream — fail loud rather
# than silently rewrite the index from an empty directory (which would drop the
# whole catalog down to the merged-in entries, or to nothing on a first publish).
shopt -s nullglob
new_charts=("$NEW_CHARTS_DIR"/*.tgz)
shopt -u nullglob
[ "${#new_charts[@]}" -gt 0 ] || fail "publish-helm-index: no .tgz found in ${NEW_CHARTS_DIR} — nothing to publish."

# MERGE_INDEX unset/empty is the genuine first publish (no catalog yet). But a
# NAMED merge target that turns out missing/empty is NOT a first publish — it is
# a broken state, and silently falling back to a no-merge publish would re-index
# only the new charts and DROP the entire existing catalog (still on disk, now
# unlisted): the worst outcome, and indistinguishable from a real first publish.
# Fail closed on that direction — the same instinct the empty-NEW_CHARTS_DIR
# guard above applies. Mirrors the workflow's index_exists guard (Asad, #1001).
if [ -n "$MERGE_INDEX" ]; then
  [ -s "$MERGE_INDEX" ] || fail "publish-helm-index: MERGE_INDEX=${MERGE_INDEX} is set but missing/empty — refusing to first-publish over an existing catalog and drop it."
  helm repo index "$NEW_CHARTS_DIR" --url "$REPO_URL" --merge "$MERGE_INDEX"
else
  helm repo index "$NEW_CHARTS_DIR" --url "$REPO_URL"
fi

# helm writes the result to <dir>/index.yaml; move it to the requested location.
# Reading MERGE_INDEX happened above, so OUT_INDEX == MERGE_INDEX is safe.
[ -f "${NEW_CHARTS_DIR}/index.yaml" ] || fail "publish-helm-index: helm did not produce ${NEW_CHARTS_DIR}/index.yaml."
mv "${NEW_CHARTS_DIR}/index.yaml" "$OUT_INDEX"

echo "publish-helm-index: wrote ${OUT_INDEX} (indexed ${#new_charts[@]} new chart(s), merged=$([ -n "$MERGE_INDEX" ] && echo yes || echo no))."
