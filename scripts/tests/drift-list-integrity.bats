#!/usr/bin/env bats
# drift-list-integrity.bats — `make drift` refuses every shape of a list that
# would run fewer guards than it claims.
#
# WHY THIS EXISTS. `DRIFT_GUARDS` is a `|`-separated list and the `drift` recipe
# is the thing that turns it into gates. Every failure mode here has the same
# shape: the run reports "all N guards green" and exits 0 while one of the N did
# not happen. That is the class this whole tier of the repo is about, and the
# recipe's own comment block says as much — but until now the three guards in it
# were asserted by a comment, having been found by hand twice (#755, and the
# doubled-`|` case when the list went one-per-line).
#
# EVERY CASE DRIVES `make drift` ITSELF, with a crafted DRIFT_GUARDS so only
# trivial guards run. Re-implementing the splitting logic here would test a copy
# of the rule and go on passing while the recipe drifted (CLAUDE.md rule 9).
#
# `true` and `false` are the guards: this suite is about the LIST, not about any
# real guard's verdict.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# Run `make drift` with an explicit list. Command-line variables override the
# Makefile's, which is what lets these cases exist at all.
drift() {
  run make -C "$REPO" drift "DRIFT_GUARDS=$1"
}

# ONE MATCHER, TWO CALLERS (Bugbot, and this file's own header rule 9).
#
# The floor case reads Make's real output; the shape case feeds it synthetic
# assignment lines. Both used to carry their OWN literal copy of this grep+sed,
# so the shape case named the floor's matcher and never reached it: narrowing or
# deleting the live matcher left it green, which is the unreachable-fixture
# shape this suite exists to refuse. Both now call this.
#
# Reads the candidate text on STDIN, prints the `|`-joined VALUE with the
# assignment prefix stripped, and fails (non-zero, no output) when no assignment
# line is present — so "cannot find it" is never indistinguishable from "found a
# list of one".
#
# THE VALUE, NOT THE COUNT, and that is what makes the STRIP testable. `awk -F'|'
# NF` gives the same answer whether or not the prefix was removed, because a
# leftover prefix just rides along inside field 1 — so a narrowed `sed` left all
# nine cases green. Measured on the count-returning version of this very
# function. Callers count; the shape case additionally asserts the value
# BYTE-EXACT, which is the only thing a wrong strip changes.
drift_guards_value() {
  local line
  line="$(grep -m1 -E '^(export )?DRIFT_GUARDS[[:space:]]*:?=')" || return 1
  [ -n "$line" ] || return 1
  printf '%s' "$line" \
    | sed -E 's/^(export )?DRIFT_GUARDS[[:space:]]*:?=[[:space:]]*//'
}

@test "an EMPTY list is a failure, not a clean sweep" {
  drift ""
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"guard list is EMPTY"* ]] || return 1
}

@test "a normal list runs every entry and says how many" {
  drift "true|true|true"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"all 3 guards green"* ]] || return 1
}

@test "a FAILING guard fails the run, and the others still ran" {
  drift "true|false|true"
  [ "$status" -ne 0 ] || return 1
  # The count in the message is the proof the run did not stop at the failure:
  # a bail-out would report fewer than 3.
  [[ "$output" == *"all 3 were run"* ]] || return 1
}

@test "a TRAILING separator is refused: the count would fall short" {
  # The `for` drops a trailing empty field, so `ran` < `exp`. This is the case
  # the count check already caught; it is pinned so the check cannot be removed
  # as redundant once the empty-entry guard below exists.
  drift "true|true|"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"refusing to report green"* ]] || return 1
}

@test "a DOUBLED separator is refused: an empty guard 'passes'" {
  # THE ONE THAT WAS OPEN. A `||` in the middle yields an empty entry; `sh -c ""`
  # exits 0 and `ran` still increments, so the count matches and the run reports
  # green with one of its guards being the empty string. Measured before the fix:
  # `DRIFT_GUARDS=true||true` printed "all 3 guards green" and exited 0.
  drift "true||true"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"EMPTY"* ]] || return 1
}

@test "an entry of only WHITESPACE is refused too" {
  # The one-per-line layout makes `|   |` as easy to type as `||`, and a space is
  # not visible in a diff. Same fail-open, so the same refusal.
  drift "true|   |true"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"EMPTY"* ]] || return 1
}

@test "a guard containing a QUOTE cannot collapse the list" {
  # #755's fail-open: the recipe used `guards='$(DRIFT_GUARDS)'`, so the first
  # guard containing a `'` ended the assignment and zero guards ran while the
  # run printed green. The value travels through the ENVIRONMENT now.
  drift "bash -c 'exit 1'|true"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"all 2 were run"* ]] || return 1
}

@test "the committed list is non-trivial, so these cases are not the only ones" {
  # FAIL CLOSED on the real list: if it ever shrinks to a couple of entries, the
  # cases above would still pass while `make drift` gated almost nothing. Read
  # from the Makefile as Make EXPANDS it, not by re-parsing the file — the value
  # the recipe sees is the one worth counting.
  #
  # THE PREFIX IS OPTIONAL, and that is a portability fix rather than a bug fix
  # (Bugbot, Medium, demoted with evidence). The claim was that GNU Make 4.x
  # renders an exported simply-expanded variable as `export DRIFT_GUARDS :=`, so
  # a `^DRIFT_GUARDS :=` matcher misses on Ubuntu CI. Measured: this suite passed
  # on Ubuntu CI as written (`bats (bash unit, mocked) = SUCCESS`), because Make
  # records the assignment and the `export` directive separately. So the finding
  # does not reproduce — but the matcher WAS depending on which of those two
  # shapes a given Make emits, and it costs one alternation not to. A miss would
  # fail closed (the `-n` check below) rather than pass silently, so this is
  # about not going red on a Make upgrade, not about a hole.
  run make -C "$REPO" -pn
  [ "$status" -eq 0 ] || return 1
  local value count
  value="$(printf '%s\n' "$output" | drift_guards_value)" || return 1
  count="$(printf '%s' "$value" | awk -F'|' '{print NF}')"
  [ "$count" -ge 20 ] || return 1
  # The strip worked: the value starts with a guard, not a leftover assignment.
  case "$value" in DRIFT_GUARDS*|export*) return 1 ;; esac
}

@test "the floor's matcher accepts BOTH shapes Make can print" {
  # The assertion above can only ever exercise the shape THIS Make emits, so the
  # other shape would be untested until a Make upgrade made it the live one —
  # exactly the gap the finding pointed at. Both are driven here directly.
  local real
  real="$(printf '%s\n' "a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u")"
  for prefix in "DRIFT_GUARDS := " "export DRIFT_GUARDS := " "DRIFT_GUARDS = " "export DRIFT_GUARDS = "; do
    local value
    value="$(printf '%s\n' "${prefix}${real}" | drift_guards_value)" || return 1
    # BYTE-EXACT: a prefix left behind changes this and changes no count.
    [ "$value" = "$real" ] || return 1
  done
  # And the control: a line that merely MENTIONS the name is not an assignment,
  # so the matcher must REFUSE it rather than strip nothing and succeed.
  #
  # THE FUNCTION IS CALLED BY ITS REAL NAME, checked because renaming it left
  # this line pointing at a function that no longer existed — `! missing_command`
  # is non-zero, `!` inverts it, and the control went on "passing" while
  # exercising nothing. A negated assertion whose subject may not exist is a coin
  # toss (CLAUDE.md rule 10).
  #
  # EXISTENCE FIRST, then the refusal. `bash -c` cannot see a bats-defined
  # function, so routing through it made every run status 127 — the same
  # not-found that the bare `!` was silently accepting. Asserting the function is
  # there is what makes the next line mean "it refused" rather than "it is gone".
  [ "$(type -t drift_guards_value)" = "function" ] || return 1
  local out rc
  out="$(printf '%s\n' "#   DRIFT_GUARDS is documented above" | drift_guards_value)" && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -z "$out" ] || return 1
}
