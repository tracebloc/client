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
  # from the Makefile as Make expands it, not by re-parsing the file.
  run make -C "$REPO" -pn
  [ "$status" -eq 0 ] || return 1
  local line count
  line="$(printf '%s\n' "$output" | grep -m1 '^DRIFT_GUARDS :=')"
  [ -n "$line" ] || return 1
  count="$(printf '%s' "${line#DRIFT_GUARDS := }" | awk -F'|' '{print NF}')"
  [ "$count" -ge 20 ] || return 1
}
