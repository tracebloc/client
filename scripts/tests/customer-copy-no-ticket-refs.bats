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
