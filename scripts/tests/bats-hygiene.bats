#!/usr/bin/env bats
# =============================================================================
#  bats-hygiene.bats — keep every assertion in this suite ENFORCING.
#
#  Bats (verified on 1.13.0) runs a test body under errexit, but two classes of
#  assertion escape it, so a failing one that is NOT the last command in the body
#  is silently ignored:
#
#    [[ ... ]]   on bash 3.2 — the system bash on macOS — errexit does not fire
#                for a failing conditional expression
#    ! cmd       POSIX: a status inverted with '!' is never propagated, so this
#                escapes on EVERY bash, not just 3.2
#
#  So a body like
#
#      run _augment_no_proxy
#      [[ "$output" == *"localhost"* ]]            # FALSE -> ignored
#      [[ "$output" == *"host.k3d.internal"* ]]    # TRUE  -> test passes
#
#  passes while ignoring the first assertion. That is not theoretical: with the
#  pre-hardening suite, deleting `localhost` from TB_NO_PROXY_DEFAULTS — the entry
#  that keeps a corporate proxy from intercepting loopback — left that exact test
#  green. Hardened, it fails. Same story for the R8 tag gate: blanking install.sh's
#  "not an immutable release tag" message left install-bootstrap.bats's two
#  path-traversal tests green, because their message assertion was a multi-line
#  `[[ a || b ]]` the scanner used to skip (Bugbot). Hardened, both fail.
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

@test "the scanner flags an internal-OR assertion: || inside the brackets is not enforcing (Bugbot)" {
  # `[[ a || b ]]` is ONE assertion whose ||/&& is internal; it exits non-zero on
  # failure exactly like a plain one, so it needs `|| return 1` too. Skipping every
  # line that merely CONTAINS ||/&& let this class through, on one line and across
  # several — including `||` that is only text inside a quoted pattern.
  local fixture="$BATS_TEST_TMPDIR/internal-or.bats" out
  {
    printf '@test "example" {\n'
    printf '  [[ "abc" == *"zzz"* || "abc" == *"yyy"* ]]\n'          # 2: internal || -> flagged
    printf '  [[ "abc" == *"zzz"* && "abc" == *"yyy"* ]]\n'          # 3: internal && -> flagged
    printf '  [ "$(grep -c \x27|| rc=$?\x27 f)" -eq 2 ]\n'           # 4: || only in a pattern -> flagged
    printf '  [[ "abc" == *"zzz"* \\\n     || "abc" == *"yyy"* ]]\n' # 5: continued, backslash -> flagged
    printf '  [[ "abc" == *"zzz"* ||\n     "abc" == *"yyy"* ]]\n'    # 7: continued, no backslash -> flagged
    printf '  [[ "abc" == *"zzz"* || "abc" == *"abc"* ]] || return 1\n'  # 9: enforcing -> spared
    printf '  [[ "abc" == *"zzz"* \\\n     || "abc" == *"a"* ]] || return 1\n' # 10: enforcing -> spared
    printf '  [[ 1 == 1 ]] || [[ 2 == 2 ]]\n'                        # 12: TOP-level chain -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  # multi-line assertions are reported at their FIRST line
  local n
  for n in 2 3 4 5 7; do
    [[ "$out" == *":$n:"* ]] || { printf 'expected line %s to be flagged, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  for n in 9 10 12; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  # each offender is one output line, and a joined one stays on one line
  [[ "$(printf '%s' "$out" | grep -c .)" == "5" ]] || return 1
}

@test "the scanner flags an un-hardened negated bare command (Bugbot)" {
  # `! cmd` is the one class that escapes errexit on EVERY bash — POSIX says a
  # status inverted with '!' is never propagated — so an unhardened one is
  # advisory everywhere, not just on bash 3.2. The suite has 61 of them.
  local fixture="$BATS_TEST_TMPDIR/negated.bats" out
  {
    printf '@test "example" {\n'
    printf '  ! mock_calls | grep -q preflight_sudo\n'               # 2: un-hardened -> flagged
    printf '  ! grep -q needle "$f"\n'                               # 3: un-hardened -> flagged
    printf '  ! mock_calls | grep -q install_docker || return 1\n'   # 4: enforcing  -> spared
    printf '  if ! grep -q needle "$f"; then :; fi\n'                # 5: control flow -> spared
    printf '  grep -q needle "$f"\n'                                 # 6: bare cmd, errexit fires -> spared
    printf '  run ! grep -q needle "$f"\n'                           # 7: bats run -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":2:"* ]] || return 1
  [[ "$out" == *":3:"* ]] || return 1
  local n
  for n in 4 5 6 7; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$(printf '%s' "$out" | grep -c .)" == "2" ]] || return 1
}

@test "the scanner does not mistake a quoted <<TAG or a herestring for a heredoc (Bugbot)" {
  # A `<<TAG` inside a quoted string is text, and `<<<` is a herestring — neither
  # opens a heredoc. Treating them as openers put the scanner into skip mode with no
  # bare terminator to leave it, so it silently ignored the REST OF THE FILE. Both
  # shapes were live: this file's own `printf "cat <<'EOF'"` line, and three
  # `run guard_leftover_data <<< "r"` lines in leftover-guard.bats.
  local fixture="$BATS_TEST_TMPDIR/fake-heredoc.bats" out n
  {
    printf '@test "example" {\n'
    printf '  echo "cat <<\x27EOF\x27"\n'                 # 2: quoted << -> NOT an opener
    printf '  [[ "abc" == *"zzz"* ]]\n'                   # 3: flagged (was invisible)
    printf '  run guard <<< "r"\n'                        # 4: herestring -> NOT an opener
    printf '  [ "1" = "2" ]\n'                            # 5: flagged (was invisible)
    printf '  cat > g <<\x27EOF\x27\n'                    # 6: a REAL heredoc opener
    printf '  [[ "embedded" == "fixture" ]]\n'            # 7: heredoc body -> spared
    printf 'EOF\n'                                        # 8: terminator
    printf '  [[ "abc" == *"yyy"* ]]\n'                   # 9: flagged
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  for n in 3 5 9; do
    [[ "$out" == *":$n:"* ]] || { printf 'expected line %s to be flagged, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  # line 7 is a genuine heredoc body and must STILL be spared — otherwise the fix
  # would just be "stop tracking heredocs at all"
  [[ "$out" != *":7:"* ]] || { printf 'line 7 (real heredoc body) must be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "3" ]] || { printf 'expected exactly 3 offenders, got:\n%s\n' "$out" >&2; return 1; }
}

@test "an unterminated heredoc cannot swallow past the next @test (Bugbot)" {
  # Belt for the same failure mode: whatever else is ever misread as an opener, the
  # skip must end at an @test in column 0, so it can never hide more than one test.
  local fixture="$BATS_TEST_TMPDIR/unterminated.bats" out
  {
    printf '@test "unterminated" {\n'
    printf '  cat > f <<\x27NOPE\x27\n'                   # 2: real opener, never terminated
    printf '  [[ "swallowed" == "ok" ]]\n'                # 3: genuinely in the body -> spared
    printf '}\n'
    printf '@test "next" {\n'                            # 5: safety valve fires here
    printf '  [ "1" = "2" ]\n'                           # 6: flagged
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":6:"* ]] || { printf 'expected line 6 to be flagged, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":3:"* ]] || { printf 'line 3 is inside the heredoc body, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "1" ]] || { printf 'expected exactly 1 offender, got:\n%s\n' "$out" >&2; return 1; }
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
