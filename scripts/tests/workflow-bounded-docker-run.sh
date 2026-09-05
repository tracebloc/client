#!/usr/bin/env bash
#
#  workflow-bounded-docker-run.sh — every `docker run` in installer-tests.yaml
#  must be wrapped in `timeout` (#986).
#
#  WHY. The Prereqs and PATH-persist jobs run the installer's real network path
#  inside a container. A stalled mirror there used to run until the job's
#  timeout-minutes fired, and a job-level cap reports `cancelled` with no
#  readable step log -- twice on 2026-09-04, on two package managers. Wrapping
#  the container run in `timeout` turns that into a FAILED step whose log ends
#  with the command that stalled. This guard keeps the wrapper from being lost
#  the next time one of those steps is edited: the bound is a property of the
#  source text, and a property read off source text passes forever once the
#  text drifts unless something reads it back.
#
#  WHAT IT CHECKS. Every non-comment line of the workflow that invokes
#  `docker run` must start with `timeout`. Lines beginning with `#` are prose
#  and are skipped. A file with NO `docker run` at all is a finding, not a
#  pass: zero bounded runs and zero unbounded runs compare equal, and "cannot
#  tell" must never read as "nothing to bound" (repo CLAUDE.md rule 3).
#
#  Usage: workflow-bounded-docker-run.sh [path-to-workflow]
#  Exit 0 = every docker run is bounded; 1 = a finding was printed.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILE="${1:-$ROOT/.github/workflows/installer-tests.yaml}"

[ -r "$FILE" ] || { echo "FAIL: cannot read $FILE" >&2; exit 1; }

# Non-comment lines that invoke `docker run`, with their line numbers.
# (while-read rather than mapfile: this also runs under macOS's bash 3.2.)
runs=()
while IFS= read -r entry; do runs+=("$entry"); done < <(
  grep -nE 'docker run' "$FILE" | grep -vE '^[0-9]+:[[:space:]]*#' || true)

if [ "${#runs[@]}" -eq 0 ]; then
  echo "FAIL: no docker run found in $FILE - the guard has nothing to check, which is not the same as every run being bounded" >&2
  exit 1
fi

rc=0
for entry in "${runs[@]}"; do
  line="${entry%%:*}"
  text="${entry#*:}"
  if ! [[ "$text" =~ ^[[:space:]]*timeout[[:space:]] ]]; then
    echo "FAIL: unbounded docker run at $FILE:$line - wrap it in \`timeout\` so a stall fails the step with a readable log instead of cancelling the job (#986)" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "OK: ${#runs[@]} docker run invocation(s) in $(basename "$FILE") are bounded by timeout"
exit "$rc"
