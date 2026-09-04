#!/usr/bin/env bash
#
#  chart-version-guard.sh — chart content ⇒ Chart.yaml version bump
#
#  Chart content can only reach installs via a NEW chart version: a Helm repo
#  publishes on version change, so an unbumped template/values edit reaches
#  nobody. This is exactly how the perIngestionTables flag block shipped to
#  staging but never rendered — PR #472 changed the template without bumping
#  Chart.yaml, so the published 1.9.7 stayed stale. This guard makes the bump
#  non-optional.
#
#  THIS REPO PUBLISHES TWO CHARTS, and they are not symmetric:
#
#    • client   — packaged as `helm package ./client --version "${TAG#v}"`, so
#                 its published version comes from the release TAG, which the
#                 release train derives from client/Chart.yaml `version:`.
#                 Bumping Chart.yaml is what moves the tag.
#    • ingestor — packaged as `helm package ./ingestor` with NO --version, so
#                 its published version IS ingestor/Chart.yaml `version:`. An
#                 unbumped edit therefore does NOT go nowhere: it OVERWRITES an
#                 already-published version. `git add ingestor-*.tgz` replaces
#                 the tarball at the same filename and `helm repo index --merge`
#                 refreshes that version's digest in place, so 0.2.0 becomes a
#                 mutable, drifting version. Measured 2026-07-31: 6 of 9 commits
#                 touching ingestor chart content never bumped Chart.yaml, and
#                 ingestor-0.2.0.tgz has been overwritten 5× since the last bump
#                 on 2026-05-20. Two installs of "0.2.0" months apart are not
#                 the same chart, and Helm caches by version, so an existing
#                 client may never pick the change up at all.
#
#  Both .tgz files land in ONE shared index.yaml, so both need the guard. The
#  chart list is DERIVED from release-helm-chart.yaml rather than hardcoded:
#  the first version of this guard hardcoded only `client` and therefore missed
#  every ingestor/** change (client#519). Deriving it from the workflow that
#  actually packages means a third chart is guarded the day it is published.
#
#  Usage: BASE_SHA=<pr base sha> bash scripts/chart-version-guard.sh
#
set -euo pipefail

RELEASE_WORKFLOW="${RELEASE_WORKFLOW:-.github/workflows/release-helm-chart.yaml}"

# Fail CLOSED on an unusable base: without a diff we cannot know whether chart
# content changed, and "don't know" must never read as "nothing changed" — that
# is the same dark ship the guard exists to stop.
if [[ -z "${BASE_SHA:-}" ]]; then
  echo "::error::Chart version guard could not determine the PR base SHA — refusing to report N/A without checking."
  exit 1
fi
if ! changed="$(git diff --name-only "${BASE_SHA}...HEAD")"; then
  echo "::error::Chart version guard could not diff ${BASE_SHA}...HEAD — refusing to report N/A without checking."
  exit 1
fi

# Which charts does the release actually package? Fail closed on an empty or
# unreadable parse — a guard that cannot tell what is published must not claim
# the PR is clean.
if ! charts="$(grep -oE 'helm package \./[A-Za-z0-9_.-]+' "$RELEASE_WORKFLOW" \
                 | sed -E 's|.*\./||' | sort -u)" || [[ -z "$charts" ]]; then
  echo "::error::Chart version guard could not read the packaged chart list from ${RELEASE_WORKFLOW} — refusing to pass without checking. If the release workflow moved, update RELEASE_WORKFLOW in scripts/chart-version-guard.sh."
  exit 1
fi
for chart in $charts; do
  if [[ ! -f "$chart/Chart.yaml" ]]; then
    echo "::error::${RELEASE_WORKFLOW} packages ./${chart} but ${chart}/Chart.yaml does not exist — refusing to guess which version file governs it."
    exit 1
  fi
done

# Does this path change what an install renders or validates?
#
# .helmignore in both charts excludes only editor/VCS junk, so everything else
# in the chart dir is packaged. Only these paths change install behaviour:
#   templates/**        rendered manifests
#   values.yaml         defaults
#   values.schema.json  Helm validates user values against the PACKAGED schema
#   charts/**, crds/**  subcharts and CRDs (none today; covered pre-emptively so
#                       adding one is not a fresh hole)
# Deliberately NOT content: ci/** and tests/** (chart-testing inputs — packaged
# but never rendered by an install) and *.md.
is_chart_content() { # $1 = chart, $2 = path
  case "$2" in
    "$1"/templates/*|"$1"/charts/*|"$1"/crds/*|"$1"/values.yaml|"$1"/values.schema.json) return 0 ;;
  esac
  return 1
}

# Did this PR change the chart's `version:` line?
#
# Read with bash builtins over a captured diff — NOT `printf … | grep -q`. Under
# `set -o pipefail`, `grep -q` closes the pipe on its FIRST match, so once the
# input passes the ~64KB pipe buffer `printf` takes SIGPIPE, the pipeline exits
# 141, and `if ! <pipeline>` reads a REAL change as "guard N/A" — silently
# skipping the bump check. Measured on ubuntu-24.04 (bash 5.2.21 / GNU grep
# 3.11): 65,622 bytes of paths already flips it. The mirror case is just as bad:
# a SIGPIPE on the MATCH short-circuits and fails a PR that DID bump. No pipe
# here ⇒ neither is reachable, and no `|| true` (which would re-introduce a
# fail-open).
version_bumped() { # $1 = chart
  local file="$1/Chart.yaml"
  local file_diff line
  if ! file_diff="$(git diff "${BASE_SHA}...HEAD" -- "$file")"; then
    echo "::error::Chart version guard could not diff ${file} — refusing to pass without checking."
    exit 1
  fi
  while IFS= read -r line; do
    case "$line" in
      '+version:'*) return 0 ;;
    esac
  done <<< "$file_diff"
  return 1
}

# ── appVersion must stay in lockstep with version, where it already is ────────
#
# `version:` gates publication (above); `appVersion:` does not — but _helpers.tpl
# feeds appVersion straight into app.kubernetes.io/version, so an appVersion left
# behind a bumped version makes the install self-report the WRONG release.
# client#964 shipped `version: 1.9.98` with `appVersion: "1.9.97"` — green
# through this guard because it only ever read `version:`; caught by Bugbot and
# review, not here.
#
# The client chart has kept version == appVersion on every bump since ~1.9.58, so
# for it any divergence is a mistake. But the two are NOT universally locked:
# ingestor versions the chart (`version:`) and the app it deploys (`appVersion:`)
# independently — 0.2.0 / 0.3.0 today, and they moved apart on separate releases.
# So the rule is NOT a blanket `version == appVersion` (that would red every
# ingestor PR); it is "a chart that WAS in lockstep at the PR base must STAY in
# lockstep." That self-scopes to client with no hardcoded chart name, exempts
# ingestor, and covers a future lockstep chart the day it starts matching.
#
# Values are compared after stripping any trailing inline comment, surrounding
# quotes, and whitespace, because `version:` is written unquoted (1.9.97) and
# `appVersion:` quoted ("1.9.97"): equal in value, and a raw string compare
# would read them as divergent.
chart_field() { # $1 = key; Chart.yaml on stdin → prints first value, rc 1 if absent
  local key="$1" line val found=1
  # Read to EOF even after the match — an early `break` would close a feeding
  # pipe and SIGPIPE its writer, the class version_bumped documents above.
  while IFS= read -r line; do
    if [[ "$found" -eq 1 ]]; then
      case "$line" in
        "$key":*)
          val="${line#"$key":}"
          # Drop a trailing YAML inline comment (whitespace + #…) before trimming,
          # as the repo's other portable readers do; a version/appVersion value
          # never contains '#', so this only ever strips a comment.
          case "$val" in *[[:space:]]"#"*) val="${val%%[[:space:]]"#"*}" ;; esac
          val="${val#"${val%%[![:space:]]*}"}"   # ltrim
          val="${val%"${val##*[![:space:]]}"}"    # rtrim
          case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
          esac
          found=0
          ;;
      esac
    fi
  done
  [[ "$found" -eq 0 ]] && printf '%s' "$val"
  return "$found"
}

# rc is shared with the version-bump loop below, so an appVersion failure reds the
# guard even on a PR whose content-change check turns out N/A.
rc=0
for chart in $charts; do
  file="$chart/Chart.yaml"

  # "In lockstep" is read from the PR BASE. A chart whose base Chart.yaml is
  # missing/unreadable, is missing either key, or already had the two diverged is
  # not a lockstep chart here — leave it to the version-bump check.
  if ! base_yaml="$(git show "${BASE_SHA}:${file}" 2>/dev/null)"; then
    continue
  fi
  base_ver="$(chart_field version    <<< "$base_yaml")" || continue
  base_app="$(chart_field appVersion <<< "$base_yaml")" || continue
  [[ "$base_ver" == "$base_app" ]] || continue

  # Locked at base ⇒ must be locked at HEAD.
  head_ver="$(chart_field version    < "$file")" || head_ver=''
  head_app="$(chart_field appVersion < "$file")" || head_app=''
  if [[ "$head_ver" != "$head_app" ]]; then
    echo "::error::${file} has version: '${head_ver}' but appVersion: '${head_app}'. ${chart}'s version and appVersion have moved in lockstep on every bump, and _helpers.tpl feeds appVersion into app.kubernetes.io/version — so a version bumped without appVersion (client#964: 1.9.98 vs 1.9.97) makes the install self-report the wrong release. Set ${file} appVersion equal to version in this PR."
    rc=1
  fi
done

# Classify every changed path per chart. One `case` per chart, and `case` with no
# matching pattern exits 0 — a `[[ … ]] && var=1` tail would itself trip `set -e`
# on a non-match.
touched=''
while IFS= read -r path; do
  for chart in $charts; do
    if is_chart_content "$chart" "$path"; then
      case " $touched " in
        *" $chart "*) ;;
        *) touched="${touched}${chart} " ;;
      esac
    fi
  done
done <<< "$changed"

# Report EVERY unbumped chart, not just the first: a PR touching both charts
# should see both in one run rather than one per push. rc may already be 1 from
# the appVersion lockstep check above, so a content-change N/A must exit "$rc",
# not 0 — otherwise an appVersion-only failure would be swallowed.
if [[ -z "${touched// /}" ]]; then
  echo "No packaged chart content changed in this PR — guard N/A."
  exit "$rc"
fi

for chart in $touched; do
  if version_bumped "$chart"; then
    echo "${chart} chart content changed and ${chart}/Chart.yaml 'version:' was bumped. ✓"
  else
    echo "::error::${chart}/templates/**, ${chart}/values.yaml or ${chart}/values.schema.json changed, but ${chart}/Chart.yaml 'version:' was NOT bumped. ${RELEASE_WORKFLOW} packages ./${chart} into the shared index.yaml, and a Helm repo only ever publishes a NEW version — so an unbumped edit either reaches no install at all or silently overwrites an already-published one. Both have happened in this repo: the perIngestionTables block shipped dark (PR #472), and ingestor-0.2.0.tgz was overwritten 5× between 2026-05-20 and 2026-07-29. Bump ${chart}/Chart.yaml 'version:' in this PR."
    rc=1
  fi
done
exit "$rc"
