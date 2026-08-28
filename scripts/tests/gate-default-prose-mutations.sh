#!/usr/bin/env bash
#
#  gate-default-prose-mutations.sh — prove gate-default-prose-agreement.sh can
#  actually FAIL on the drift it was written for (backend#1528, Bugbot on #900).
#
#  WHY THIS FILE EXISTS, and it is the guard's own class one level up. The
#  guard's header claimed "the mutation test in this suite re-inserts the
#  original stale sentence to prove the finding is reachable". No such test
#  existed: the mutations had been run by hand in a shell and never committed.
#  A docstring asserting a check nobody can run is exactly what
#  gate-default-prose-agreement.sh was added to stop, so leaving it unbacked
#  would have been the guard failing its own rule in its own comment
#  (repo CLAUDE.md rule 7). This file is that claim made executable.
#
#  HOW. The guard derives its ROOT from its own path, so each case COPIES the
#  four inputs it reads into a throwaway tree, mutates the copy, and runs the
#  guard from there. The real repo is never written to.
#
#  Every case asserts the SPECIFIC finding text, never a bare non-zero exit
#  (rule 10): a guard that fails for the wrong reason and a guard that works
#  produce the same exit status, and only the message can tell them apart.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GUARD="$ROOT/scripts/tests/gate-default-prose-agreement.sh"
[ -r "$GUARD" ] || { echo "FAIL: $GUARD missing" >&2; exit 1; }

pass=0; fail=0

# Build a throwaway copy of everything the guard reads.
mkfixture() {                       # $1 = destination root
  local d="$1"
  mkdir -p "$d/scripts/tests" "$d/client/templates" "$d/docs/migration-tools"
  cp "$GUARD" "$d/scripts/tests/"
  cp "$ROOT/client/values.yaml" "$ROOT/client/values.schema.json" "$d/client/"
  cp "$ROOT/client/templates/_helpers.tpl" "$d/client/templates/"
  # Every markdown file the guard globs, at its real relative path.
  ( cd "$ROOT" && find client docs -name '*.md' -type f -print0 ) \
    | while IFS= read -r -d '' f; do
        mkdir -p "$d/$(dirname "$f")"
        cp "$ROOT/$f" "$d/$f"
      done
}

run_case() {                        # $1 label, $2 expected rc, $3 expected substring, $4 fixture root
  local label="$1" want_rc="$2" want="$3" d="$4" out rc
  set +e
  out=$(bash "$d/scripts/tests/gate-default-prose-agreement.sh" 2>&1); rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    printf '  [FAIL] %s -- exit %s, wanted %s\n' "$label" "$rc" "$want_rc"
    printf '%s\n' "$out" | sed 's/^/         | /'
    fail=$((fail + 1)); return
  fi
  # HERE-STRING, not a pipe: `grep -q` closes its input on the first match, and
  # under `set -o errexit -o pipefail` the SIGPIPE that gives the writer fails
  # the whole pipeline -- so a PASSING case would report as a failure. Caught by
  # `quality / pipefail early-close`, which is a required check here.
  if ! grep -qF -- "$want" <<<"$out"; then
    printf '  [FAIL] %s -- exit %s as expected but the message did not name it\n' "$label" "$rc"
    printf '         wanted substring: %s\n' "$want"
    printf '%s\n' "$out" | sed 's/^/         | /'
    fail=$((fail + 1)); return
  fi
  printf '  [ok]   %s\n' "$label"
  pass=$((pass + 1))
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== gate-default-prose-agreement: can it fail? =="

# ---- 1. the tree as shipped must be clean -----------------------------------
# Not decoration: every case below is a DIFFERENCE against this, so a baseline
# that was already red would make each of them meaningless.
D="$TMP/base"; mkfixture "$D"
run_case "the tree as shipped agrees with its own defaults" 0 "no document contradicts" "$D"

# ---- 2. markdown drift, in the exact words that shipped ---------------------
# This is the sentence that was live in MIGRATION.md while the chart shipped
# rotateMysqlRootByEnv.dev = true. Backticks included, because they are the
# whole reason normalisation exists (case 4).
D="$TMP/md"; mkfixture "$D"
python3 - "$D/client/MIGRATION.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "`rotateMysqlRootByEnv` were added in `1.9.71`."
assert s.count(old) == 1, f"fixture anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(
    old,
    "`rotateMysqlRootByEnv` were added in `1.9.71`; they are `false` for `dev`, "
    "`stg` and `prod`, so an upgrade changes nothing on its own."))
PY
run_case "a stale runbook sentence is caught, backticks and all" 1 \
  "MIGRATION.md" "$D"

# ---- 3. values.yaml's OWN comment, in the words that shipped ----------------
D="$TMP/vals"; mkfixture "$D"
python3 - "$D/client/values.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "# This is the LAST, prod-irreversible-adjacent step of the rollout. It is ON for"
assert s.count(old) == 1, f"fixture anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(
    old,
    "# This is the LAST, prod-irreversible-adjacent step of the rollout, so it is OFF\n"
    "# everywhere by default. It was ON for"))
PY
run_case "a stale values.yaml comment is caught, and 'OFF' counts as 'false'" 1 \
  "client/values.yaml" "$D"

# ---- 4. normalisation is LOAD-BEARING, not cosmetic -------------------------
# The anti-proof for case 2. Disable the markdown normaliser and the same stale
# sentence goes unseen -- which is what "widening the corpus without stripping
# emphasis would have been theatre" means, demonstrated rather than asserted.
D="$TMP/nonorm"; mkfixture "$D"
python3 - "$D/client/MIGRATION.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "`rotateMysqlRootByEnv` were added in `1.9.71`."
assert s.count(old) == 1
open(p, "w").write(s.replace(
    old,
    "`rotateMysqlRootByEnv` were added in `1.9.71`; they are `false` for `dev`, "
    "`stg` and `prod`, so an upgrade changes nothing on its own."))
PY
python3 - "$D/scripts/tests/gate-default-prose-agreement.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '_MD_STRIP = re.compile(r"[*_`]+")'
assert s.count(old) == 1, f"normaliser anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(old, '_MD_STRIP = re.compile(r"(?!x)x")   # mutation: strips nothing'))
PY
run_case "WITHOUT normalisation the same sentence is missed (so it is load-bearing)" 0 \
  "no document contradicts" "$D"

# ---- 5. a correct claim about ANOTHER gate must not fire --------------------
# docs/SECURITY.md's identity table says, correctly, "On for `dev` via
# `perExperimentDbCredsByEnv`, off for `stg`/`prod`". Paragraph-scoped
# attribution charged that `off for stg` to serviceDbAccounts three rows away.
# Case 1 covers this, but it is asserted by name so the reason survives.
D="$TMP/nofp"; mkfixture "$D"
grep -q "perExperimentDbCredsByEnv" "$D/docs/SECURITY.md" \
  || { echo "  [FAIL] fixture lost SECURITY.md's identity table" >&2; fail=$((fail + 1)); }
run_case "a correct row about one gate is not charged to another" 0 \
  "no document contradicts" "$D"

# ---- 6. a checkout path with a SPACE ----------------------------------------
# Regression, and it was live: the markdown list was a whitespace-split string,
# so on the primary dev checkout (`.../Claude File System/...`) the guard tried
# to read `/Users/lukas/Documents/Claude` and failed closed on EVERY run. CI
# never saw it -- runners check out to a space-free path -- and `shellcheck -S
# warning` does not either, because SC2086 is severity INFO. Every other case
# here builds its fixture under mktemp, which has no spaces, so without this
# case the suite would be blind to it too.
D="$TMP/with space/root"; mkfixture "$D"
run_case "a checkout path containing a space still resolves the corpus" 0 \
  "no document contradicts" "$D"

# ---- 7. fail closed on an empty corpus --------------------------------------
D="$TMP/nomd"; mkfixture "$D"
find "$D/client" "$D/docs" -name '*.md' -type f -delete
# ---- the ON-polarity mirror, which the guard could not catch ----------------
# saqlainsyed007 on #900: TRUE_CLAIMS lacked the LIST form and `default on`, so
# a stale on-polarity claim naming a still-off env did not redden while its
# off-polarity twin did. These three cases are the missing direction, and each
# FAILED against the pre-fix guard.

# (a) list form, on-polarity, naming an env that ships false.
D="$TMP/onlist"; mkfixture "$D"
python3 - "$D/client/MIGRATION.md" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
old = "`rotateMysqlRootByEnv` were added in `1.9.71`."
assert s.count(old) == 1, f"fixture anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(
    old,
    "`rotateMysqlRootByEnv` were added in `1.9.71`; it is `true` for `dev`, "
    "`stg` and `prod`, so every fleet rotates on upgrade."))
PY2
run_case "an ON-polarity claim in LIST form is caught (stg/prod ship false)" 1   "MIGRATION.md" "$D"

# (b) the `baked on` prefix in list form -- the same shape via the other prefix.
D="$TMP/onbaked"; mkfixture "$D"
python3 - "$D/client/MIGRATION.md" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
old = "`rotateMysqlRootByEnv` were added in `1.9.71`."
assert s.count(old) == 1, f"fixture anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(
    old,
    "`rotateMysqlRootByEnv` were added in `1.9.71`; it is baked `on` for `dev`, "
    "`stg` and `prod`."))
PY2
run_case "an ON-polarity 'baked on for <list>' claim is caught too" 1   "MIGRATION.md" "$D"

# (c) THE FALSE-POSITIVE GUARD, which the fix for (a) needed and which the
# shipped off-side patterns would also have failed. Every one of these documents
# states BOTH polarities in one sentence; a greedy list span crosses the other
# polarity word and reports "says true for stg" about a sentence that says
# exactly the opposite. 18 such findings appeared the moment the on-side was
# completed. This case is the CORRECT sentence and must stay GREEN -- it is the
# only thing standing between the guard and a wall of false findings.
D="$TMP/mixed"; mkfixture "$D"
python3 - "$D/client/MIGRATION.md" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
old = "`rotateMysqlRootByEnv` were added in `1.9.71`."
assert s.count(old) == 1, f"fixture anchor matched {s.count(old)} times, not 1"
open(p, "w").write(s.replace(
    old,
    "`rotateMysqlRootByEnv` were added in `1.9.71`; it is `true` for `dev` and "
    "`false` for `stg` and `prod`, which is what the chart ships."))
PY2
run_case "a sentence stating BOTH polarities correctly is NOT a finding" 0   "no document contradicts" "$D"

# Re-established here rather than relying on the `$D` set above: the cases
# inserted between that setup and this assertion silently repointed `$D`, and
# the case then ran against a fixture nobody built for it. Setting it adjacent
# to its own run_case is the only version an insertion cannot break.
D="$TMP/nomd2"; mkfixture "$D"
find "$D/client" "$D/docs" -name '*.md' -type f -delete
run_case "zero markdown files is a FINDING, not agreement" 1 "fail closed" "$D"

# ---- 8. fail closed when an input cannot be read ----------------------------
D="$TMP/noschema"; mkfixture "$D"
rm -f "$D/client/values.schema.json"
run_case "an unreadable schema is a FINDING, not agreement" 1 "unreadable" "$D"

printf '\ngate-default-prose-mutations: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
