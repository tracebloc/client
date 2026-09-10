#!/usr/bin/env bats
# customer-copy-no-ticket-refs.sh — no internal tracker identifier in a string a
# customer can see.
#
# Every case calls the REAL guard against a scratch copy of scripts/: the same
# function is what the clean run and the mutation runs exercise, so a parser
# that drifts from the script reddens here rather than proving a copy of itself.
# Fixture files (the vocabulary-derivation cases) are written out independently
# of the parser they exercise.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="$REPO/scripts/tests/customer-copy-no-ticket-refs.sh"
  # A copy, always: these tests plant offenders and corrupt the manifest.
  WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/copyrefs.XXXXXX")"
  cp -R "$REPO/scripts" "$WORK/scripts"
}

teardown() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  return 0
}

run_guard() { bash "$GUARD" "$WORK" "$@"; }

# plant FILE LINE — append LINE to FILE and PROVE it landed (rule 5: an inert
# mutation and real coverage look identical in a log).
plant() {
  printf '%s\n' "$2" >> "$WORK/$1"
  [ "$(grep -cF -- "$2" "$WORK/$1")" -eq 1 ] || return 1
}

@test "the committed tree is clean" {
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"shipped files scanned"* ]] || return 1
}

# --- mutations: the guard reddens on what it claims to catch ---------------

@test "mutation: a warn carrying backend#<n> in a manifest-listed lib reddens" {
  plant scripts/lib/cluster.sh 'warn "planted copy (backend#1)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/cluster.sh:"*"backend#1"* ]] || { echo "$output"; return 1; }
}

@test "mutation: an Err carrying RFC-<nnnn> in the Windows sub-script reddens" {
  plant scripts/install-k8s.ps1 'Err "planted copy (RFC-9901)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/install-k8s.ps1:"*"RFC-9901"* ]] || { echo "$output"; return 1; }
}

@test "mutation: a bootstrap is in scope even though the manifest cannot list it" {
  plant scripts/install.sh 'echo "planted copy, see backend#1" >&2'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/install.sh:"*"backend#1"* ]] || { echo "$output"; return 1; }
  plant scripts/install.ps1 'Warn "planted copy (RFC-9901)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/install.ps1:"*"RFC-9901"* ]] || { echo "$output"; return 1; }
}

@test "mutation: an emitter after || is copy too (compound error line)" {
  plant scripts/lib/cluster.sh 'do_thing || error "planted after or (backend#1)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/cluster.sh:"*"planted after or (backend#1)"* ]] || return 1
}

@test "mutation: an emitter inside || { …; } is copy too" {
  plant scripts/lib/cluster.sh 'do_thing || { echo "[ERROR] planted in a group (RFC-9901)" >&2; exit 1; }'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted in a group (RFC-9901)"* ]] || return 1
}

@test "mutation: an emitter on a one-line case arm is copy too" {
  plant scripts/lib/cluster.sh 'case "$x" in 2) warn "planted on a case arm (backend#11)";; esac'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted on a case arm (backend#11)"* ]] || return 1
}

@test "mutation: an emitter after then/else on one line is copy too" {
  plant scripts/lib/cluster.sh 'if [ -z "$x" ]; then warn "planted after then (backend#2)"; else warn "ok"; fi'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted after then (backend#2)"* ]] || return 1
}

@test "mutation: a PowerShell emitter inside a one-line if block is copy too" {
  plant scripts/install-k8s.ps1 'if (-not $ok) { Write-Host "planted in a block (RFC-9903)"; exit 1 }'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted in a block (RFC-9903)"* ]] || return 1
}

@test "an emitter name that is only an argument or a substring is NOT a command start" {
  # `myecho` is not `echo`; `some_unknown_cmd` emits nothing and its argument
  # merely mentions `warn`. Neither line starts a command from the vocabulary.
  plant scripts/lib/cluster.sh 'myecho "not copy (backend#3)"'
  plant scripts/lib/cluster.sh 'some_unknown_cmd "the word warn appears here (backend#4)"'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- review round (client#1020): token shapes, comment stripping, derivation -----

@test "mutation: a cross-repo identifier (client#<n>, .github#<n>) is copy the customer cannot open" {
  plant scripts/lib/cluster.sh 'warn "planted cross-repo (client#564 migration)"'
  plant scripts/lib/cluster.sh 'warn "planted dotted repo (.github#306)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"client#564 migration"* ]] || return 1
  [[ "$output" == *".github#306"* ]] || return 1
}

@test "mutation: the org's RFC-<AREA>-<nnnn> form is caught, not only RFC-<nnnn>" {
  plant scripts/lib/cluster.sh 'warn "planted alpha rfc (RFC-BACKEND-0007 D1)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"RFC-BACKEND-0007"* ]] || return 1
}

@test "shell parameter expansion with a # is not an identifier" {
  plant scripts/lib/cluster.sh 'warn "trimmed ${x#0} of ${#arr[@]} items, argc $#"'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a token in a trailing comment that contains an apostrophe is NOT flagged" {
  plant scripts/lib/cluster.sh 'warn "clean visible text"  # we don'"'"'t ship backend#5 anymore'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a # inside a quoted string is not a comment: the token after it is still flagged" {
  plant scripts/lib/cluster.sh 'warn "issue #5 is fixed, see backend#7"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"backend#7"* ]] || return 1
}

@test "derivation: a helper whose closing brace is indented is still classified" {
  printf 'shout_indented() {\n    echo "$*"\n    }\nafter_indented() {\n  echo "$*"\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  plant scripts/lib/cluster.sh 'after_indented "planted after an indented close (backend#8)"'
  run run_guard "$WORK" --print-vocab bash
  [[ "$output" == *"shout_indented"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"after_indented"* ]] || { echo "$output"; return 1; }
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted after an indented close (backend#8)"* ]] || return 1
}

@test "derivation: a definition with its brace on the next line is classified" {
  printf 'shout_nextline()\n{\n  echo "$*"\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  run run_guard "$WORK" --print-vocab bash
  [[ "$output" == *"shout_nextline"* ]] || { echo "$output"; return 1; }
}

@test "derivation: a here-document with unbalanced braces inside a helper does not break the walk" {
  printf 'banner_heredoc() {\n  cat <<EOF\n  { this brace never closes\nEOF\n  echo "$*"\n}\nafter_heredoc() { echo "$*"; }\n' >> "$WORK/scripts/lib/cluster.sh"
  run run_guard "$WORK" --print-vocab bash
  [[ "$output" == *"banner_heredoc"* && "$output" == *"after_heredoc"* ]] || { echo "$output"; return 1; }
}

@test "derivation: a QUOTED here-document (<<'X', <<\"X\", <<-'X') with unbalanced braces does not break the walk" {
  printf "help_quoted() {\n  cat <<'HELP'\n  { this brace never closes, and neither does this one {\nHELP\n  echo \"\$*\"\n}\n" >> "$WORK/scripts/lib/cluster.sh"
  printf 'help_dquoted() {\n  cat <<"HELP2"\n  } stray close\nHELP2\n  echo "$*"\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  printf "help_dash() {\n\tcat <<-'HELP3'\n\t{ indented\n\tHELP3\n\techo \"\$*\"\n}\nafter_quoted() { echo \"\$*\"; }\n" >> "$WORK/scripts/lib/cluster.sh"
  run run_guard "$WORK" --print-vocab bash
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for fn in help_quoted help_dquoted help_dash after_quoted; do
    [[ "$output" == *"$fn"* ]] || { echo "missing $fn"; echo "$output"; return 1; }
  done
}

@test "mutation: an identifier inside a quoted here-document body (help text) is copy too" {
  printf "help_planted() {\n  cat <<'HELP'\n  Usage: tracebloc install\n  See the migration notes (backend#12) before upgrading.\nHELP\n}\n" >> "$WORK/scripts/lib/cluster.sh"
  grep -q 'migration notes (backend#12)' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"migration notes (backend#12)"* ]] || return 1
}

@test "mutation: an identifier inside a PowerShell here-string (Write-Host @\"…\"@) is copy too" {
  printf 'function Show-Planted {\n  Write-Host @"\n  Set up your environment.\n  See the migration notes (backend#14) first.\n"@\n}\n' >> "$WORK/scripts/install-k8s.ps1"
  grep -q 'migration notes (backend#14)' "$WORK/scripts/install-k8s.ps1" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/install-k8s.ps1:"*"migration notes (backend#14)"* ]] || return 1
}

@test "the guard is a named DRIFT_GUARDS entry, so make drift and the drift job run it" {
  grep -qE '^[[:space:]]*bash scripts/tests/customer-copy-no-ticket-refs\.sh\|\\$' "$REPO/Makefile" || return 1
}

@test "fail closed: a helper whose braces never balance is a guard error, not a shorter vocabulary" {
  printf 'broken_open() {\n  echo "never closed"\n' >> "$WORK/scripts/lib/cluster.sh"
  grep -q '^broken_open() {' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"broken_open"*"still open at end of file"* ]] || { echo "$output"; return 1; }
}

@test "derivation: an echo that lives only in a comment does not make a helper an emitter" {
  printf 'quiet_helper() {\n  # this used to echo the value\n  return 0\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  plant scripts/lib/cluster.sh 'quiet_helper "not copy (backend#9)"'
  run run_guard "$WORK" --print-vocab bash
  [[ "$output" != *"quiet_helper"* ]] || { echo "$output"; return 1; }
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "mutation: the count names every offender, not just the first" {
  plant scripts/lib/cluster.sh 'warn "planted one (backend#1)"'
  plant scripts/lib/probe.sh 'hint "planted two (RFC-9902)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/cluster.sh:"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/probe.sh:"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"2 user-visible line(s)"* ]] || { echo "$output"; return 1; }
}

# --- deliberate scope: comments are not customer copy -----------------------

@test "a comment line carrying a token is NOT flagged" {
  plant scripts/lib/cluster.sh '# rationale lives here (backend#1, RFC-9901)'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a token in a trailing comment on an emitter line is NOT flagged" {
  plant scripts/lib/cluster.sh 'warn "plain words a customer reads"  # why: backend#1'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- fail closed: 'could not check' is a finding -----------------------------

@test "fail closed: an unreadable manifest is a guard error, not a pass" {
  rm "$WORK/scripts/manifest.sha256"
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"cannot read"* ]] || { echo "$output"; return 1; }
}

@test "fail closed: an empty manifest is a guard error, not a pass" {
  : > "$WORK/scripts/manifest.sha256"
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"zero files"* ]] || { echo "$output"; return 1; }
}

@test "fail closed: a scan stage that fails is a guard error, not a clean file" {
  # A manifest-listed path that is a DIRECTORY passes the readability check but
  # makes the first grep exit 2 ("Is a directory"). Under one `grep | sed | grep`
  # pipeline with pipefail, the trailing grep's no-match (1) masked that 2 and the
  # file read as clean; staged, the 2 is a guard error (Bugbot on client#1020).
  mv "$WORK/scripts/lib/probe.sh" "$WORK/scripts/lib/probe.sh.bak"
  mkdir "$WORK/scripts/lib/probe.sh"
  [ -d "$WORK/scripts/lib/probe.sh" ] || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"grep failed (2) selecting copy lines in scripts/lib/probe.sh"* ]] || { echo "$output"; return 1; }
}

@test "fail closed: a manifest entry with no file behind it is a guard error" {
  plant scripts/manifest.sha256 'deadbeef  scripts/lib/not-there.sh'
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"missing or unreadable: scripts/lib/not-there.sh"* ]] || { echo "$output"; return 1; }
}

# --- the vocabulary is derived from the shipped files ------------------------

# Point the scratch manifest at fixtures only, and stub the bash bootstrap so
# the bash vocabulary can come from nothing but the fixture. install.ps1 stays:
# the PowerShell side is asserted by contains/not-contains, not by equality.
use_fixtures() {
  mkdir -p "$WORK/scripts/lib"
  cat > "$WORK/scripts/lib/fixture.sh" <<'FX'
#!/usr/bin/env bash
oneliner()   { echo -e "  $*"; }
withcomment(){ printf '%s\n' "$*"; }   # trailing comment after the brace
multiline() {
  local x="$1"
  printf '  %s\n' "$x" >&2
}
silent()     { command -v "$1" >/dev/null 2>&1; }
silent_multi() {
  local y
  y="$(date)"
}
FX
  cat > "$WORK/scripts/lib/fixture.ps1" <<'FX'
function OneLiner($m) { Write-Host "  $m" }
function MultiLine {
  param($m)
  Write-Warning $m
}
function Silent($m) { Get-Date }
FX
  printf '%s\n' 'x  scripts/lib/fixture.sh' 'x  scripts/lib/fixture.ps1' > "$WORK/scripts/manifest.sha256"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub bootstrap, no functions"' > "$WORK/scripts/install.sh"
}

@test "derivation: one-line and multi-line emitters are seen, non-emitters are not" {
  use_fixtures
  run run_guard --print-vocab bash
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for want in echo printf oneliner withcomment multiline; do
    grep -qx "$want" <<<"$output" || { echo "missing $want in: $output"; return 1; }
  done
  for nope in silent silent_multi; do
    ! grep -qx "$nope" <<<"$output" || { echo "$nope wrongly derived: $output"; return 1; }
  done
  run run_guard --print-vocab ps
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for want in Write-Host throw OneLiner MultiLine; do
    grep -qx "$want" <<<"$output" || { echo "missing $want in: $output"; return 1; }
  done
  ! grep -qx Silent <<<"$output" || { echo "Silent wrongly derived: $output"; return 1; }
}

@test "derivation: the derived names drive the scan (a fixture emitter is honoured)" {
  use_fixtures
  plant scripts/lib/fixture.sh 'oneliner "planted (backend#7)"'
  plant scripts/lib/fixture.ps1 'MultiLine "planted (RFC-9907)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/fixture.sh:"*"backend#7"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/lib/fixture.ps1:"*"RFC-9907"* ]] || { echo "$output"; return 1; }
  # ...and a non-emitter carrying the same token is not copy.
  use_fixtures
  plant scripts/lib/fixture.sh 'silent "not copy (backend#7)"'
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "fail closed: a derivation that finds no bash emitter is a guard error" {
  use_fixtures
  printf '%s\n' '#!/usr/bin/env bash' 'silent() { command -v "$1"; }' > "$WORK/scripts/lib/fixture.sh"
  run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"derived ZERO copy-emitting bash helpers"* ]] || { echo "$output"; return 1; }
}

# --- second review round (client#1020): escapes, here-document text, one lexer ---

@test "derivation: an escaped quote around an unbalanced brace inside a string does not move the depth (bash)" {
  # Old walker: `\"` toggled quote state, so the `{` counted as a real brace and the
  # first helper never balanced (guard error), while a `}` closed the second early.
  printf 'say_escaped() {\n  echo "open \\"{ deeper\\" now"\n}\nsay_escaped_close() {\n  echo "close \\"} early\\" now"\n  echo "$*"\n}\nafter_escaped() { echo "$*"; }\n' >> "$WORK/scripts/lib/cluster.sh"
  grep -qF 'echo "open \"{ deeper\" now"' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  plant scripts/lib/cluster.sh 'after_escaped "planted after an escaped quote (backend#15)"'
  run run_guard "$WORK" --print-vocab bash
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for fn in say_escaped say_escaped_close after_escaped; do
    grep -qx "$fn" <<<"$output" || { echo "missing $fn"; echo "$output"; return 1; }
  done
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted after an escaped quote (backend#15)"* ]] || { echo "$output"; return 1; }
}

@test "derivation: a backtick-escaped or doubled quote around a brace does not move the depth (PowerShell)" {
  printf 'function Say-Escaped {\n  Write-Host "he said `"go { deeper`" now"\n}\nfunction Say-Doubled {\n  Write-Host "he said ""go } early"" now"\n}\nfunction After-Escaped($m) { Write-Host $m }\n' >> "$WORK/scripts/install-k8s.ps1"
  grep -qF 'Write-Host "he said `"go { deeper`" now"' "$WORK/scripts/install-k8s.ps1" || return 1   # anchor applied
  plant scripts/install-k8s.ps1 'After-Escaped "planted after an escaped quote (RFC-9908)"'
  run run_guard "$WORK" --print-vocab ps
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for fn in Say-Escaped Say-Doubled After-Escaped; do
    grep -qx "$fn" <<<"$output" || { echo "missing $fn"; echo "$output"; return 1; }
  done
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted after an escaped quote (RFC-9908)"* ]] || { echo "$output"; return 1; }
}

@test "mutation: a # inside a PRINTED here-document body is text the customer reads, not a comment" {
  printf "help_hash() {\n  cat <<'HELP'\n  # migration required, see backend#16\n  Some line   # tracked in backend#17\nHELP\n}\n" >> "$WORK/scripts/lib/cluster.sh"
  grep -q 'tracked in backend#17' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"migration required, see backend#16"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"tracked in backend#17"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"2 user-visible line(s)"* ]] || { echo "$output"; return 1; }
}

@test "a # inside a here-document that GENERATES A FILE is that file's comment; its other lines are still copy" {
  # The values.yaml the installer writes carries the rationale for its defaults
  # as YAML comments -- out of scope like every other comment.
  printf 'write_values() {\n  cat <<EOF > "$1"\n# rationale for this default (backend#19)\nreplicas: 1   # see RFC-9909\nEOF\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  grep -q 'rationale for this default (backend#19)' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # ...but a non-comment line of the generated file is text the customer can open.
  printf 'write_values_token() {\n  cat <<EOF > "$1"\nnote: planted in a generated file (backend#20)\nEOF\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted in a generated file (backend#20)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"backend#19"* ]] || { echo "$output"; return 1; }
}

@test "a # inside an ASSIGNED PowerShell here-string is that file's comment; its other lines are still copy" {
  printf 'function Write-Values {\n  $values = @"\n# rationale for this default (backend#21)\nreplicas: 1\n"@\n  Set-Content -Path $p -Value $values\n}\n' >> "$WORK/scripts/install-k8s.ps1"
  grep -q 'rationale for this default (backend#21)' "$WORK/scripts/install-k8s.ps1" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'function Write-Values-Token {\n  $values = @"\nnote: planted in an assigned here-string (backend#23)\n"@\n}\n' >> "$WORK/scripts/install-k8s.ps1"
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted in an assigned here-string (backend#23)"* ]] || { echo "$output"; return 1; }
}

@test "mutation: the org's RFC-<AREA>-<nnn> form with three digits is caught" {
  plant scripts/lib/cluster.sh 'warn "planted short rfc (RFC-BACKEND-664)"'
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"RFC-BACKEND-664"* ]] || { echo "$output"; return 1; }
}

@test "a here-document body line that starts with an emitter word is reported once, not twice" {
  printf "help_once() {\n  cat <<'HELP'\n  echo is what this prints, see backend#18\nHELP\n}\n" >> "$WORK/scripts/lib/cluster.sh"
  grep -q 'echo is what this prints, see backend#18' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'backend#18' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"1 user-visible line(s)"* ]] || { echo "$output"; return 1; }
}

@test "derivation: a PowerShell here-string closed by \"@.Trim() does not swallow every later function" {
  # The old closer rule wanted the closer ALONE on its line, so `"@.Trim()` in
  # install-k8s.ps1 left the here-string open for ~2,750 lines and hid eleven
  # emitting helpers from the vocabulary (a silent miss).
  printf 'function Get-Script {\n  return @"\necho hi\n"@.Trim()\n}\nfunction After-Trim($m) { Write-Host $m }\n' >> "$WORK/scripts/install-k8s.ps1"
  grep -qF '"@.Trim()' "$WORK/scripts/install-k8s.ps1" || return 1   # anchor applied
  plant scripts/install-k8s.ps1 'After-Trim "planted after a trimmed here-string (RFC-9910)"'
  run run_guard "$WORK" --print-vocab ps
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx After-Trim <<<"$output" || { echo "$output"; return 1; }
  ! grep -qx Get-Script <<<"$output" || { echo "Get-Script emits nothing"; echo "$output"; return 1; }
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"planted after a trimmed here-string (RFC-9910)"* ]] || { echo "$output"; return 1; }
}

@test "one lexer: the quote/comment walk and the here-document delimiter rule are defined once" {
  [ "$(grep -c 'function lex(' "$GUARD")" -eq 1 ] || return 1
  [ "$(grep -c 'function code_only(' "$GUARD")" -eq 1 ] || return 1
  [ "$(grep -c 'sub(/\.\*<<-?' "$GUARD")" -eq 1 ] || return 1
  [ "$(grep -c 'function herestring_closer(' "$GUARD")" -eq 1 ] || return 1
}

# --- Bugbot round on the follow-up: redirect classification, scratch dir ------

@test "a printed here-document with a stderr or /dev redirect is still text, not a generated file" {
  printf "help_quiet() {\n  cat <<'HELP' 2>/dev/null\n  # see backend#24 before upgrading\nHELP\n}\nhelp_err() {\n  cat <<'HELP' >/dev/stderr\n  # see backend#25 before upgrading\nHELP\n}\nhelp_fd() {\n  cat <<'HELP' >&2\n  # see backend#26 before upgrading\nHELP\n}\n" >> "$WORK/scripts/lib/cluster.sh"
  grep -q 'see backend#26 before upgrading' "$WORK/scripts/lib/cluster.sh" || return 1   # anchor applied
  run run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  for t in 'backend#24' 'backend#25' 'backend#26'; do
    [[ "$output" == *"$t before upgrading"* ]] || { echo "missing $t"; echo "$output"; return 1; }
  done
  [[ "$output" == *"3 user-visible line(s)"* ]] || { echo "$output"; return 1; }
  # ...while an explicit stdout-to-file redirect (`1>`) is a generated file.
  printf 'write_one() {\n  cat <<EOF 1> "$1"\n# rationale (backend#27)\nEOF\n}\n' >> "$WORK/scripts/lib/cluster.sh"
  run run_guard
  [[ "$output" != *"backend#27"* ]] || { echo "$output"; return 1; }
}

@test "fail closed: a scratch directory that cannot be created is a guard error, never a cleanup of /" {
  TMPDIR="$WORK/does-not-exist" run run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"could not create a scratch directory"* ]] || { echo "$output"; return 1; }
}
