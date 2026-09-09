#!/usr/bin/env bash
#
#  check-chart-contents.sh — a packaged chart carries no test suites or CI values
#
#  The published client-1.9.107.tgz held 45 of its 96 entries under
#  client/tests/ and client/ci/ (39 % of its bytes): 41 helm-unittest suites
#  whose filenames narrate the chart's hardening history, plus the four
#  ci/*-values.yaml files. Nothing consumes them from the tarball — helm-unittest
#  and the lint/ct jobs run on the source checkout — so they were dead weight on
#  every `helm pull`. The fix is two lines in each chart's .helmignore; this
#  guard is what keeps them there, by reading the ARTEFACT `helm package` just
#  produced rather than trusting the ignore file.
#
#  Refused (exit 1, every offending path named):
#    * any member under a chart-root `tests/` or `ci/` directory;
#  Cannot tell (exit 2, never reported as clean):
#    * no tarball named, a tarball that cannot be listed, a listing with no
#      members, or one with no `<chart>/Chart.yaml` (then it is not a chart and
#      the scan would be looking at the wrong thing).
#
#  Only CHART-ROOT `tests/` and `ci/` are refused. Helm's own test-hook
#  convention lives at `templates/tests/` and must stay shippable -- which is
#  why the .helmignore rules are written `/tests/` and `/ci/` (leading slash):
#  Helm matches an unanchored `tests/` against every path component and would
#  drop that hook directory too. The bats suite packages a fixture chart under
#  the real .helmignore to hold both halves of the rule together.
#
#  NEVER `producer | grep -q` HERE (Bugbot on client#515, scripts/index-
#  invariants.sh): the listing is written to a FILE and grepped there, so a
#  SIGPIPE can never turn a real finding into "clean".
#
#  Usage:
#    bash scripts/check-chart-contents.sh <chart>.tgz [<chart>.tgz ...]
#
set -euo pipefail

# ::error:: goes to STDOUT: Actions parses workflow commands from stdout only
# (Bugbot, client#497).
fail()   { echo "::error::$1"; exit 2; }
refuse() { echo "::error::$1"; exit 1; }

#: Chart-root directories that must not ship. One declaration, with the reason
#: beside each entry; the matching .helmignore rules are the mechanism and this
#: list is the check on the artefact they produce.
FORBIDDEN_DIRS=(
  tests   # helm-unittest suites; run from the source tree, never from the tgz
  ci      # chart-testing / lint values per platform; CI reads the checkout
)

[ "$#" -ge 1 ] || fail "check-chart-contents: no chart tarball named — refusing to report a chart as clean without one to read."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pattern=""
for d in "${FORBIDDEN_DIRS[@]}"; do
  pattern="${pattern:+$pattern|}$d"
done
# `<chart>/<dir>/...` — the first path component is the chart name helm prefixes
# every member with, the second is the directory under test.
regex="^[^/]+/(${pattern})/"

status=0
for tgz in "$@"; do
  [ -f "$tgz" ] || fail "check-chart-contents: ${tgz} does not exist — cannot list what is not there."
  listing="$tmp/$(basename "$tgz").list"
  if ! tar -tzf "$tgz" >"$listing" 2>"$tmp/tar.err"; then
    fail "check-chart-contents: could not list ${tgz} ($(tr '\n' ' ' <"$tmp/tar.err")) — an unreadable tarball is not a clean one."
  fi
  [ -s "$listing" ] || fail "check-chart-contents: ${tgz} lists no members — an empty tarball is not a chart."
  rc=0
  grep -qE '^[^/]+/Chart\.yaml$' "$listing" || rc=$?
  [ "$rc" -le 1 ] || fail "check-chart-contents: grep exited ${rc} while looking for Chart.yaml in ${tgz}."
  [ "$rc" -eq 0 ] || fail "check-chart-contents: ${tgz} carries no <chart>/Chart.yaml — not a Helm chart, so this scan does not apply to it."
  rc=0
  hits="$(grep -E "$regex" "$listing")" || rc=$?
  [ "$rc" -le 1 ] || fail "check-chart-contents: grep exited ${rc} while scanning ${tgz}."
  if [ "$rc" -eq 0 ]; then
    n="$(printf '%s\n' "$hits" | grep -c .)"
    echo "::error::check-chart-contents: ${tgz} ships ${n} member(s) under a chart-root $(IFS=/; echo "${FORBIDDEN_DIRS[*]}") directory — the .helmignore rule did not hold:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    status=1
  else
    total="$(grep -c . "$listing")"
    echo "check-chart-contents: ${tgz} clean (${total} members, none under a chart-root $(IFS=/; echo "${FORBIDDEN_DIRS[*]}") directory)."
  fi
done

[ "$status" -eq 0 ] || refuse "check-chart-contents: a packaged chart ships test suites or CI values; add the directory to the chart's .helmignore."
echo "check-chart-contents: every packaged chart ships only what helm installs."
