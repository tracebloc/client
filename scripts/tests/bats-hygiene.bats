#!/usr/bin/env bats
# =============================================================================
#  bats-hygiene.bats — keep every assertion in this suite ENFORCING.
#
#  Under Bats (verified on 1.13.0) a failing command that is NOT the last one in a
#  test body does NOT fail the test — only the final command's exit status is
#  checked. So a body like
#
#      run _augment_no_proxy
#      [[ "$output" == *"localhost"* ]]            # FALSE -> ignored
#      [[ "$output" == *"host.k3d.internal"* ]]    # TRUE  -> test passes
#
#  passes while ignoring the first assertion. That is not theoretical: with the
#  pre-hardening suite, deleting `localhost` from TB_NO_PROXY_DEFAULTS — the entry
#  that keeps a corporate proxy from intercepting loopback — left that exact test
#  green. Hardened, it fails.
#
#  Convention: every standalone assertion inside an @test body ends in
#  `|| return 1`. The scanner lives in unenforced-assertions.awk (one
#  implementation, shared by the guard and its own self-test below).
# =============================================================================

setup() {
  SCANNER="${BATS_TEST_DIRNAME}/unenforced-assertions.awk"
  TESTS_DIR="${BATS_TEST_DIRNAME}"
}

@test "every standalone assertion in an @test body ends in '|| return 1' (else it is advisory)" {
  local offenders count
  offenders="$(awk -f "$SCANNER" "$TESTS_DIR"/*.bats)"
  count="$(printf '%s' "$offenders" | grep -c . || true)"
  if [[ "$count" != "0" ]]; then
    printf 'Found %s assertion(s) that cannot fail their test:\n\n' "$count" >&2
    printf '%s\n\n' "$offenders" >&2
    printf 'Append "|| return 1" to each. See the header of this file for why.\n' >&2
    return 1
  fi
  [[ "$count" == "0" ]] || return 1
}

@test "the scanner flags an un-hardened assertion and spares a hardened one (guard is not vacuous)" {
  # A guard nobody has watched fail is not a guard. Build the fixture with printf,
  # not a heredoc, so this file contains no line that looks like a bare assertion.
  local fixture="$BATS_TEST_TMPDIR/fixture.bats" out
  {
    printf '@test "example" {\n'
    printf '  [[ "abc" == *"zzz"* ]]\n'                 # line 2: un-hardened -> flagged
    printf '  [ "1" = "2" ]\n'                          # line 3: un-hardened -> flagged
    printf '  [[ "abc" == *"abc"* ]] || return 1\n'      # line 4: enforcing  -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":2:"* ]] || return 1
  [[ "$out" == *":3:"* ]] || return 1
  [[ "$out" != *":4:"* ]] || return 1
}

@test "the scanner ignores control flow, chained lines, helpers and heredoc bodies" {
  local fixture="$BATS_TEST_TMPDIR/quiet.bats" out
  {
    printf 'helper() {\n'
    printf '  [[ -n "$x" ]]\n'                          # outside @test -> ignored
    printf '}\n'
    printf '@test "example" {\n'
    printf '  if [[ -n "$x" ]]; then :; fi\n'           # control flow -> ignored
    printf '  [[ -n "$x" ]] || fail "nope"\n'           # already chained -> ignored
    printf "  cat > f <<'EOF'\n"
    printf '  [[ "embedded" == "fixture" ]]\n'          # heredoc body -> ignored
    printf 'EOF\n'
    printf '  [[ 1 == 1 ]] || return 1\n'
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ -z "$out" ]] || return 1
}
