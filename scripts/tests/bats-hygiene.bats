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

@test "the scanner is not fooled by '|| return 1' inside a pattern or comment (Bugbot)" {
  # The enforcing check was a line-wide substring match, so any assertion whose
  # quoted pattern or trailing comment merely MENTIONED `|| return 1` was treated as
  # hardened though neither enforces. Both must still be flagged; a real top-level
  # `|| return 1` is still spared.
  local fixture="$BATS_TEST_TMPDIR/substr.bats" out
  {
    printf '@test "example" {\n'
    printf '  [[ "$output" == *"|| return 1"* ]]\n'              # 2: marker in a pattern -> flagged
    printf '  [ "$x" = "y" ]   # remember to add || return 1\n'  # 3: marker in a comment -> flagged
    printf '  [[ "$output" == *"ok"* ]] || return 1\n'          # 4: really hardened -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":2:"* ]] || return 1
  [[ "$out" == *":3:"* ]] || return 1
  [[ "$out" != *":4:"* ]] || return 1
  [[ "$(printf '%s' "$out" | grep -c .)" == "2" ]] || return 1
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

@test "the scanner flags a bracket / negated assertion that is the last command of a compound line (Bugbot)" {
  # `run x; [[ ... ]]` puts the `[[` mid-line, not at line start; on bash 3.2 the
  # `[[` still cannot fail the test, so it is advisory. The preflight suite is
  # full of these (`run _pf_disk; [[ "$output" == *…* ]]`).
  local fixture="$BATS_TEST_TMPDIR/compound.bats" out
  {
    printf '@test "example" {\n'
    printf '  run _pf_disk; [[ "$output" == *"free"* ]]\n'          # 2: bracket last -> flagged
    printf '  x=0; check >/dev/null; [ "$x" -eq 0 ]\n'              # 3: single-bracket last -> flagged
    printf '  run _pf_disk; ! grep -q needle "$f"\n'               # 4: negated last -> flagged
    printf '  run x; [[ "$output" == *"free"* ]] || return 1\n'    # 5: enforcing -> spared
    printf '  run x; [[ "$o" == *"a"* ]] || fail msg\n'            # 6: top-level chain -> spared
    printf '  a=1; b=2\n'                                          # 7: bare cmds -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":2:"* ]] || return 1
  [[ "$out" == *":3:"* ]] || return 1
  [[ "$out" == *":4:"* ]] || return 1
  local n
  for n in 5 6 7; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$(printf '%s' "$out" | grep -c .)" == "3" ]] || return 1
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

@test "the scanner follows the test body across a nested function's braces (Bugbot)" {
  # A `name() { ... }` stub inside an @test — e.g. a `helm() { cat <<'YAML' ... }`
  # mock — closes with a column-0 `}`. Ending the scan at the FIRST such `}` (instead
  # of tracking brace depth) skipped every assertion after the stub. check-drift.bats
  # had exactly this: an un-hardened `[ "$_drift" -ge 1 ]` after a helm() stub.
  local fixture="$BATS_TEST_TMPDIR/nested.bats" out
  {
    printf '@test "nested" {\n'                     # 1
    printf '  helm() { cat <<\x27YAML\x27\n'         # 2: nested-fn brace + heredoc opener
    printf 'kind: Deployment\n'                      # 3: heredoc body -> spared
    printf 'YAML\n'                                  # 4: terminator
    printf '}\n'                                      # 5: closes helm() at column 0
    printf '  [ "$x" -ge 1 ]\n'                      # 6: AFTER the nested } -> flagged
    printf '  [[ "$y" == ok ]] || return 1\n'        # 7: hardened -> spared
    printf '}\n'                                      # 8: real end of the @test
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":6:"* ]] || { printf 'expected line 6 to be flagged, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":3:"* ]] || { printf 'line 3 (heredoc body) must be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":7:"* ]] || { printf 'line 7 (hardened) must be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "1" ]] || { printf 'expected exactly 1 offender, got:\n%s\n' "$out" >&2; return 1; }
}

@test "the scanner scans one-line @test bodies (Bugbot)" {
  # `@test "x" { run foo; [ "$status" -eq 0 ]; }` puts the whole body on the @test
  # line. Consuming that line as merely an opener never scanned the inline assertion.
  # common.bats has two of these (`has: present command` / `has: absent command`).
  local fixture="$BATS_TEST_TMPDIR/oneline.bats" out
  {
    printf '@test "unhardened" { run has bash; [ "$status" -eq 0 ]; }\n'            # 1: flagged
    printf '@test "hardened" { run has bash; [ "$status" -eq 0 ] || return 1; }\n'  # 2: spared
    printf '@test "no assertion" { run has bash; }\n'                               # 3: spared
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":1:"* ]] || { printf 'expected line 1 to be flagged, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":2:"* ]] || { printf 'line 2 (hardened) must be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":3:"* ]] || { printf 'line 3 (no assertion) must be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "1" ]] || { printf 'expected exactly 1 offender, got:\n%s\n' "$out" >&2; return 1; }
}

@test "a semicolon inside a subshell does not split a hardened assertion (Bugbot)" {
  # Splitting a compound line on ';' to check each statement must ignore a ';' inside
  # a ( ) subshell or $( ) substitution, or `! ( a; b ) || return 1` is torn into
  # `! ( a` and reported though it is hardened. probe.bats has three of these.
  local fixture="$BATS_TEST_TMPDIR/subshell.bats" out n
  {
    printf '@test "subshell" {\n'                              # 1
    printf '  ! ( cd /tmp; grep -q needle f ) || return 1\n'   # 2: ; in ( ) -> spared
    printf '  x=$(a; b); [ -n "$x" ] || return 1\n'            # 3: ; in $( ) -> spared
    printf '  ! ( cd /tmp; grep -q needle f )\n'               # 4: UNHARDENED -> flagged
    printf '}\n'                                                # 5
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":4:"* ]] || { printf 'expected line 4 to be flagged, got:\n%s\n' "$out" >&2; return 1; }
  for n in 2 3; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$(printf '%s' "$out" | grep -c .)" == "1" ]] || { printf 'expected exactly 1 offender, got:\n%s\n' "$out" >&2; return 1; }
}

@test "a ||/&& only inside quotes or a subshell is not a top-level chain (Bugbot)" {
  # The chain exemption must see a REAL top-level `||`/`&&`, not one that appears only
  # inside a quoted pattern (`! grep -q "a||b"`) or a `( )` subshell — else an
  # unhardened negated command is silently treated as already chained.
  local fixture="$BATS_TEST_TMPDIR/chain-quotes.bats" out n
  {
    printf '@test "chain" {\n'
    printf '  ! grep -q "a||b" f\n'                 # 2: || in quotes -> flagged
    printf '  ! grep -q "a&&b" f\n'                 # 3: && in quotes -> flagged
    printf '  ! ( cd /tmp; grep -q x f )\n'         # 4: unhardened subshell -> flagged
    printf '  ! grep -q "x||y" f || return 1\n'     # 5: really hardened -> spared
    printf '  ! grep -q x f || fail msg\n'          # 6: top-level chain -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  for n in 2 3 4; do
    [[ "$out" == *":$n:"* ]] || { printf 'expected line %s flagged, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  for n in 5 6; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$(printf '%s' "$out" | grep -c .)" == "3" ]] || { printf 'expected 3 offenders, got:\n%s\n' "$out" >&2; return 1; }
}

@test "a bracket that opens mid-line and continues across lines is joined and flagged (Bugbot)" {
  # `run x; [[ a ||` continued onto the next line opens the bracket mid-line, not at
  # line start; the join must still assemble it, or a multi-line compound bracket is
  # never seen. Reported at its FIRST line.
  local fixture="$BATS_TEST_TMPDIR/compound-multiline.bats" out
  {
    printf '@test "compound" {\n'
    printf '  run foo; [[ "$o" == *"a"* ||\n'        # 2: opens mid-line, continues
    printf '     "$o" == *"b"* ]]\n'                 # 3: closes -> unhardened -> flagged at 2
    printf '  run bar; [[ "$o" == *"c"* ||\n'        # 4: continues
    printf '     "$o" == *"d"* ]] || return 1\n'     # 5: hardened -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  [[ "$out" == *":2:"* ]] || { printf 'expected line 2 flagged, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$out" != *":4:"* ]] || { printf 'line 4 (hardened) should be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "1" ]] || { printf 'expected 1 offender, got:\n%s\n' "$out" >&2; return 1; }
}

@test "one-line tests with a bare or no-space closer are still scanned (Bugbot)" {
  # A one-liner whose bracket sits directly before the group-closing `}` (`[ a ] }`,
  # or the no-space `[ a ]}` / `[[ a ]]}` where the closer is not even recognised)
  # must still be flagged. Valid bats needs a `;` before `}`, which already splits
  # the assertion off — this is belt-and-suspenders for the degenerate shapes.
  local fixture="$BATS_TEST_TMPDIR/bare-closer.bats" out n
  {
    printf '@test "a" { run foo; [ "$s" -eq 0 ] }\n'              # 1: bare } -> flagged
    printf '@test "b" { run foo; [ "$s" -eq 0 ]}\n'               # 2: no-space ]} -> flagged
    printf '@test "c" { run foo; [[ "$o" == x ]]}\n'              # 3: ]]} -> flagged
    printf '@test "d" { run foo; [ "$s" -eq 0 ] || return 1; }\n' # 4: hardened -> spared
    printf '@test "e" { run foo; }\n'                             # 5: no assertion -> spared
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  for n in 1 2 3; do
    [[ "$out" == *":$n:"* ]] || { printf 'expected line %s flagged, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  for n in 4 5; do
    [[ "$out" != *":$n:"* ]] || { printf 'line %s should be spared, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$(printf '%s' "$out" | grep -c .)" == "3" ]] || { printf 'expected 3 offenders, got:\n%s\n' "$out" >&2; return 1; }
}

@test "a bracket closer inside a quoted pattern is not mistaken for the end (Bugbot)" {
  # after_close finds `]]`/`]` by a blank-before/blank-after heuristic; it must also
  # skip a closer that sits INSIDE quotes (`[[ "$x" == "a ]] b" ]]`), or the real
  # closer at the end is missed and an unhardened assertion looks non-standalone.
  local fixture="$BATS_TEST_TMPDIR/quoted-closer.bats" out n
  {
    printf '@test "q" {\n'
    printf '  [[ "$x" == "a ]] b" ]]\n'                 # 2: quoted ]] -> real closer at end -> flagged
    printf '  [ "$x" = "] y" ]\n'                        # 3: quoted ] -> flagged
    printf '  run z; [[ "$o" == "p ]] q" ]]\n'           # 4: compound + quoted ]] -> flagged
    printf '  [[ "$x" == "a ]] b" ]] || return 1\n'      # 5: hardened -> spared
    printf '}\n'
  } > "$fixture"

  out="$(awk -f "$SCANNER" "$fixture")"
  for n in 2 3 4; do
    [[ "$out" == *":$n:"* ]] || { printf 'expected line %s flagged, got:\n%s\n' "$n" "$out" >&2; return 1; }
  done
  [[ "$out" != *":5:"* ]] || { printf 'line 5 (hardened) should be spared, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(printf '%s' "$out" | grep -c .)" == "3" ]] || { printf 'expected 3 offenders, got:\n%s\n' "$out" >&2; return 1; }
}
