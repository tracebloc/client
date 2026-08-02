#!/usr/bin/env bash
#
#  index-invariants.sh — the public helm index holds only stable versions
#
#  Post-publish backstop for the release workflow: turns the 2026-07-29 manual
#  leak catch into CI. index.yaml on gh-pages IS the customer surface — a
#  prerelease indexed there is offered to every `helm repo update`.
#
#  Two invariants, checked against an index.yaml the caller has already read:
#    1. No prerelease-shaped chart version (a `-` in the version) is indexed.
#    2. A prerelease release run has not indexed its OWN version.
#
#  NEVER `producer | grep -q` HERE. Under `set -o pipefail`, `grep -q` closes
#  the pipe on its FIRST match; the producer takes SIGPIPE and exits 141, the
#  pipeline reports 141, and `if <pipeline>` reads a REAL LEAK as "invariants
#  hold" — the guard fails OPEN in exactly the case it exists to catch (Bugbot
#  on client#515; same class as the chart-version guard's own SIGPIPE bug,
#  scripts/chart-version-guard.sh). Every check below greps a FILE and branches
#  on grep's own three exit codes: 0 = found, 1 = not found, >=2 = could not
#  check. "Could not check" is never "clean" — it fails closed.
#
#  Usage:
#    INDEX_FILE=<path to index.yaml> TAG=<vX.Y.Z> PRERELEASE=<true|false> \
#      bash scripts/index-invariants.sh
#
set -euo pipefail

# ::error:: goes to STDOUT, not stderr: Actions parses workflow commands from
# stdout only, so an ::error:: on stderr fails the step with no annotation
# (Bugbot, client#497).
fail() { echo "::error::$1"; exit 1; }

INDEX_FILE="${INDEX_FILE:-}"
TAG="${TAG:-}"
PRERELEASE="${PRERELEASE:-}"

# Fail CLOSED on an unusable read. An empty or missing index is "don't know",
# and "don't know" must never be reported as "the invariants hold".
[ -n "$INDEX_FILE" ] || fail "index-invariants: INDEX_FILE is not set — refusing to report the invariants as holding without an index to check."
[ -f "$INDEX_FILE" ] || fail "index-invariants: ${INDEX_FILE} does not exist — refusing to report the invariants as holding on a missing read."
[ -s "$INDEX_FILE" ] || fail "index-invariants: could not read index.yaml from gh-pages — refusing to report the invariants as holding on an empty read."

# grep a FILE (never a pipe) and hand back its own exit status. 0 match /
# 1 no match / >=2 grep itself failed. `|| rc=$?` keeps `set -e` from taking
# the non-match as fatal without flattening the three states into two.
scan() { # $1 = description, then grep args; sets $scan_out, returns grep's rc
  local what="$1"; shift
  local rc=0
  scan_out="$(grep -n "$@" "$INDEX_FILE")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    fail "index-invariants: grep exited ${rc} while checking ${what} in ${INDEX_FILE} — refusing to report the invariants as holding without a usable scan."
  fi
  return "$rc"
}
scan_out=''

#  1. No prerelease-shaped chart version may ever be indexed.
#
#  index.yaml lists each chart's version on its own indented `version:` line;
#  a `-` in a semver version is a prerelease identifier (1.9.8-rc1). Matched in
#  ONE grep rather than `grep version: | grep -- -`, so there is no pipe whose
#  exit status could decide the verdict.
if scan "prerelease-shaped versions" -E '^[[:space:]]+version:[[:space:]]*[^[:space:]]*-'; then
  printf '%s\n' "$scan_out"
  fail "public helm index contains prerelease-shaped versions (above) — customer surface polluted."
fi

#  2. A prerelease run must not have indexed its own version.
if [ "$PRERELEASE" = "true" ]; then
  [ -n "$TAG" ] || fail "index-invariants: PRERELEASE=true but TAG is empty — refusing to report the leak check as passing without a version to look for."
  # -F: the tag is data, not a pattern. -e: a tag could legitimately start with
  # a `-` and must not be read as a flag.
  if scan "the release's own version" -F -e "${TAG#v}"; then
    printf '%s\n' "$scan_out"
    fail "prerelease ${TAG} leaked into the public index."
  fi
fi

echo "Index invariants hold: no prerelease-shaped versions indexed${PRERELEASE:+, PRERELEASE=${PRERELEASE}}."
