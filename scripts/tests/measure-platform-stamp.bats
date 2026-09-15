#!/usr/bin/env bats
# =============================================================================
#  measure-platform-stamp.bats — a node-reservation record must be stamped with
#  the platform it was MEASURED on, and WSL2 is the case that breaks the obvious
#  implementation.
#
#  WHY THIS EXISTS (backend#2460). gen-node-reservation-embed.sh buckets records
#  by `platform.os` and emits one kubeReserved/systemReserved pair per bucket, so
#  the stamp does not describe the record — it SELECTS which installed platform's
#  reservation the record moves. On Windows the installer's k3d nodes live in the
#  WSL2 VM, so measure-node-reservation.sh runs inside WSL2, where `uname -s`
#  answers `Linux`. Stamping from uname there would fold Windows' footprint into
#  the measured `linux` reservation: a wrong number, on a platform three records
#  already depend on, produced by a run that is green and silent.
#
#  These tests drive the harness's OWN resolution through its print seam
#  (TB_MEASURE_PRINT_PLATFORM), not a re-statement of the rule — a detector
#  re-implemented in the test would keep passing while the real one drifted.
# =============================================================================

# `run --separate-stderr` (test 5) needs the 1.5.0 flag semantics declared, or
# bats warns on every run. CI and the Homebrew formula are both well past it.
bats_require_minimum_version 1.5.0

setup() {
  MEASURE="${BATS_TEST_DIRNAME}/measure-node-reservation.sh"
  [ -x "$MEASURE" ] || [ -r "$MEASURE" ] || return 1
}

# Resolve the platform through the harness itself.
resolve() { TB_MEASURE_PRINT_PLATFORM=1 bash "$MEASURE" "$@"; }

@test "the platform is resolved and printed without creating anything" {
  # The title is the property, so the body has to pin it: the print seam is only
  # safe for the other tests BECAUSE it exits before the harness does any of its
  # real work. Asserting status + a known key would leave the title true by
  # accident and green after the seam grew a side effect (a partial record from
  # the EXIT trap, a $TB_MEASURE_OUT file, a k3d call).
  local out="$BATS_TEST_TMPDIR/should-not-exist.json"
  run env -u TB_MEASURE_PLATFORM -u WSL_DISTRO_NAME -u WSL_INTEROP \
      TB_MEASURE_OUT="$out" bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == "Darwin" || "$output" == "Linux" || "$output" == "Windows" ]] || return 1
  [ ! -e "$out" ] || return 1
}

@test "inside WSL2 the record is a WINDOWS record, not a Linux one" {
  # The whole point of the ticket's trap: `uname -s` here is `Linux`.
  [ "$(uname -s)" = "Linux" ] || skip "WSL detection only applies to a Linux shell"
  run env -u TB_MEASURE_PLATFORM WSL_DISTRO_NAME=Ubuntu-22.04 bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "Windows" ] || return 1
}

@test "a Linux shell that is NOT WSL still stamps Linux (the detection is not a blanket rewrite)" {
  [ "$(uname -s)" = "Linux" ] || skip "only meaningful on a Linux shell"
  run env -u TB_MEASURE_PLATFORM -u WSL_DISTRO_NAME -u WSL_INTEROP bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "Linux" ] || return 1
}

@test "TB_MEASURE_PLATFORM agreeing with the host is accepted, case-insensitively" {
  local detected
  detected="$(env -u TB_MEASURE_PLATFORM bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE")"
  run env TB_MEASURE_PLATFORM="$(printf '%s' "$detected" | tr '[:upper:]' '[:lower:]')" bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$detected" ] || return 1
}

@test "TB_MEASURE_PLATFORM disagreeing with the host REFUSES — it cannot mint a foreign record" {
  local detected wrong
  detected="$(env -u TB_MEASURE_PLATFORM bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE")"
  case "$detected" in
    Windows) wrong=linux ;;
    *)       wrong=windows ;;
  esac
  # --separate-stderr, so the refusal (stderr) and the stamp (stdout) can be told
  # apart. The property is that the refusal emits NO platform at all: the seam
  # prints the resolved key on stdout, so an empty stdout is the assertion that a
  # foreign platform was never minted.
  #
  # The line this replaces was `[[ "$output" != *"$wrong"*"record for"* ]]`, and
  # it could not fail: `record for` is printed only by the success banner, which
  # this invocation never reaches, so the right-hand side was absent under every
  # outcome and the test would have passed with the refusal deleted -- the one
  # thing it is named for. Caught in review, not by the mutation pass, because
  # the two assertions above it were doing the real work and reddened correctly.
  run --separate-stderr env TB_MEASURE_PLATFORM="$wrong" bash -c 'TB_MEASURE_PRINT_PLATFORM=1 bash "$0"' "$MEASURE"
  [ "$status" -eq 2 ] || return 1
  [[ "$stderr" == *"but this host detects as"* ]] || return 1
  [ -z "$output" ] || return 1
}

@test "the generator buckets on the field the harness stamps (they cannot drift apart)" {
  # Derive both ends rather than restating either: the generator's bucket key and
  # the harness's stamped field must be the same JSON path, or a correct record
  # lands in the wrong reservation.
  local gen="${BATS_TEST_DIRNAME}/../gen-node-reservation-embed.sh"
  grep -q 'rec\["platform"\]\["os"\]\.lower()' "$gen" || return 1
  grep -q 'platform: {os: \$platform' "${BATS_TEST_DIRNAME}/measure-node-reservation.sh" || return 1
  # EVERY site that feeds `platform` must feed the resolved value. Counting, not
  # presence: the harness writes the field twice (the full record and the partial
  # one the EXIT trap saves), so a `grep -q` for the good form stays green while
  # the OTHER site regresses to `uname`. That exact vacuity was caught by
  # mutation-proving this test, not by reading it.
  local total resolved
  total="$(grep -c -- '--arg platform ' "${BATS_TEST_DIRNAME}/measure-node-reservation.sh")"
  resolved="$(grep -c -- '--arg platform "\$PLATFORM_OS"' "${BATS_TEST_DIRNAME}/measure-node-reservation.sh")"
  [ "$total" -ge 2 ] || return 1
  [ "$total" -eq "$resolved" ] || return 1
}

@test "every committed record is stamped with a platform the installers actually read" {
  # A record whose platform key no installer has a table for is a measurement
  # nobody can apply — and it would create a bucket, and therefore a row, in the
  # generated block. Fail closed on an unreadable record rather than skipping it.
  local records="${BATS_TEST_DIRNAME}/../spec/node-reservation"
  [ -d "$records" ] || return 1
  local n=0 f os
  for f in "$records"/*.json; do
    [ -r "$f" ] || return 1
    os="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platform"]["os"].lower())' "$f")" || return 1
    case "$os" in darwin|linux|windows) ;; *) return 1 ;; esac
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 1
}
