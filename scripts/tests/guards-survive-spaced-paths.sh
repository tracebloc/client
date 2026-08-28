#!/usr/bin/env bash
#
#  guards-survive-spaced-paths.sh — the drift guards must work from a checkout
#  whose PATH CONTAINS A SPACE.
#
#  WHY THIS EXISTS, MEASURED. `gate-default-prose-agreement.sh` shipped with
#  `python3 - ... $MDFILES` unquoted, so the file list word-split on whitespace.
#  The primary dev checkout lives under `.../Claude File System/...`, so the guard
#  tried to read `/Users/lukas/Documents/Claude` and failed closed --
#  "cannot tell, which is a finding" -- on EVERY local run.
#
#  NEITHER EXISTING CHECK COULD SEE IT, and that is the point of this file:
#    * CI never reproduces it. GitHub runners check out to
#      `/home/runner/work/client/client`. No spaces, ever, so the guard was green
#      in the required job and permanently red on the one machine most likely to
#      break what it guards.
#    * `shellcheck` does not gate on it. SC2086 ("double quote to prevent word
#      splitting") is severity **info**, and this repo gates at `-S warning`.
#      Verified: `shellcheck -S warning` exits 0 on the broken version.
#
#  So the only thing that can catch this class is running a guard from a spaced
#  path, which is what this does -- in CI, where the path otherwise never has one.
#
#  SCOPE, deliberately narrow. It exercises the guards that walk the FILESYSTEM
#  for a set of files, because those are the ones a spaced path breaks. A guard
#  that only reads three fixed paths through quoted variables cannot exhibit this,
#  and sweeping all 31 into a copied tree would trade a precise check for a slow
#  one.
#
#  FAILS CLOSED: an empty guard list, a copy that did not land, or an unreadable
#  temp tree is a FAILURE. "We could not set the scenario up" must not pass as
#  "the guards are fine".
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Guards that enumerate files from the filesystem, and so can word-split a path.
# Listed rather than derived because the property is "walks the tree", which is
# not something a grep can tell you reliably -- but the list is ASSERTED to exist
# below, so a rename cannot leave this silently checking nothing.
GUARDS=(
  scripts/tests/gate-default-prose-agreement.sh
)

for g in "${GUARDS[@]}"; do
  [ -x "$ROOT/$g" ] || { echo "FAIL: $g is missing or not executable -- this test would check nothing" >&2; exit 1; }
done
[ "${#GUARDS[@]}" -gt 0 ] || { echo "FAIL: no guards listed; an empty sweep passes vacuously" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# The space is the whole point.
SPACED="$TMP/has space/repo"
mkdir -p "$SPACED"
for d in client docs scripts; do
  cp -R "$ROOT/$d" "$SPACED/$d" || { echo "FAIL: could not copy $d into the spaced tree -- cannot tell" >&2; exit 1; }
done
[ -f "$SPACED/client/values.yaml" ] || { echo "FAIL: the copy did not land (no values.yaml) -- cannot tell" >&2; exit 1; }
case "$SPACED" in *" "*) ;; *) echo "FAIL: the temp path has no space, so this test cannot reproduce the bug" >&2; exit 1 ;; esac

fails=0
for g in "${GUARDS[@]}"; do
  printf '  %-52s ' "$(basename "$g")"
  if out=$(cd "$SPACED" && bash "./$g" 2>&1); then
    echo "OK from a spaced path"
  else
    echo "FAILED from a spaced path"
    printf '%s\n' "$out" | sed 's/^/      | /' | head -6
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails guard(s) break when the checkout path contains a space." >&2
  echo "      Almost always an unquoted expansion of a path list (SC2086, severity" >&2
  echo "      info, so \`shellcheck -S warning\` will not tell you). Read a file list" >&2
  echo "      into an ARRAY and expand it as \"\${arr[@]}\"." >&2
  exit 1
fi
echo "guards-survive-spaced-paths: OK -- ${#GUARDS[@]} guard(s) run from a path containing a space"
