#!/usr/bin/env bats
# check-style.sh — the prose/terminology gate (backend#1924, backend#1729 sweep 6).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Sweep 6 measured that of the 24 shell scripts under scripts/ (excluding
# scripts/tests/ itself), exactly two were referenced by no bats suite.
# gen-manifest.sh was the other, and it got client#707. This is the residual.
#
# The stake is lower than gen-manifest's on purpose — an inert style guard costs
# drifting wording, not unverified code running privileged steps — but the reason
# to cover it is the same: an uncovered gate is a gate nobody can prove fires,
# and this one now sits inside the REQUIRED "Source-of-truth drift" check, so a
# rule that silently stopped matching would read as "clean" forever.
#
# SHAPE (from client#707): every rule is tested BOTH ways — it fires on a
# violation AND passes on the clean equivalent. One-sided tests are the trap
# here: a rule whose regex stopped matching anything passes every
# "clean input is clean" assertion while enforcing nothing.
#
# The brand-colour vocabulary is DERIVED from the script's own `brand=` regex
# rather than restated (backend#1729 rule 1/6). A hand-copied list of tones would
# agree with itself while a newly added tone went untested — the exact vocabulary
# gap mutation coverage cannot see.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # A copy, always: these tests plant violations and corrupt the tree, and must
  # never touch the working tree (same rule as gen-manifest.bats).
  WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/style.XXXXXX")"
  cp -R "$REPO/scripts" "$WORK/scripts"
  CS="$WORK/scripts/check-style.sh"
  # The planted-violation file. NOT under scripts/tests/ — the scanner excludes
  # that directory, so a fixture there would prove nothing (and every "it fires"
  # test would pass for the wrong reason).
  FIXTURE="$WORK/scripts/lib/zz-style-fixture.sh"
}

teardown() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  return 0
}

# The real script, run the way CI runs it.
run_style() { ( cd "$WORK" && bash scripts/check-style.sh ) }

# Plant lines in a scanned .sh file.
fixture() { printf '%s\n' "$@" > "$FIXTURE"; }

# ── the clean baseline ───────────────────────────────────────────────────────
# If this ever fails, every "fires on a violation" test below is meaningless:
# they would be measuring the working tree's own violations, not the plant.

@test "the working tree is clean (baseline — the rest of this suite depends on it)" {
  run run_style
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ok: style + terminology clean"* ]] || return 1
}

# ── rule 1: hardcoded brand colour ───────────────────────────────────────────

# Pull the tone vocabulary out of the script instead of restating it.
_brand_hexes() {
  local line re
  line="$(grep -m1 '^brand=' "$CS")"
  re="${line#brand=\'}"; re="${re%\'}"
  re="${re#*\#?(}"
  printf '%s' "${re%%)*}" | tr '|' ' '
}
_brand_rgbs() {
  local line re
  line="$(grep -m1 '^brand=' "$CS")"
  re="${line#brand=\'}"; re="${re%\'}"
  re="${re##*38;2;(}"
  printf '%s' "${re%%)*}" | tr '|' ' '
}

@test "rule 1: EVERY brand hex the script declares is caught (vocabulary derived, not restated)" {
  local hexes count=0
  hexes="$(_brand_hexes)"
  [ -n "$hexes" ] || return 1          # fail closed: an unparsed vocabulary is a finding
  for h in $hexes; do
    fixture "  local c=\"#${h}\""
    run run_style
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"hardcoded brand colour"* ]] || return 1
    count=$((count + 1))
  done
  [ "$count" -ge 6 ] || return 1       # the declared palette, not a subset
}

@test "rule 1: EVERY brand RGB triple the script declares is caught" {
  local rgbs count=0
  rgbs="$(_brand_rgbs)"
  [ -n "$rgbs" ] || return 1
  for t in $rgbs; do
    fixture "  printf '\\033[38;2;${t}m'"
    run run_style
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"hardcoded brand colour"* ]] || return 1
    count=$((count + 1))
  done
  [ "$count" -ge 5 ] || return 1
}

@test "rule 1: caught case-insensitively (#01A5CC is the same violation as #01a5cc)" {
  fixture '  local c="#01A5CC"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"hardcoded brand colour"* ]] || return 1
}

@test "rule 1: a NON-brand colour is clean (the rule discriminates, it is not 'any hex')" {
  fixture '  local c="#123456"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 1: the colour engine itself is exempt (it is where the tones legitimately live)" {
  # Same violation text, placed in common.sh — the one file the report filters out.
  printf '\n  local c="#01a5cc"\n' >> "$WORK/scripts/lib/common.sh"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 2: banned term 'workspace' ──────────────────────────────────────────

@test "rule 2: 'workspace' in user-facing text is caught" {
  fixture '  echo "your workspace is ready"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"banned term 'workspace'"* ]] || return 1
}

@test "rule 2: the approved wording is clean" {
  fixture '  echo "your secure environment is ready"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 2: comments and the DNS-1123 sanitiser identifiers are exempt" {
  fixture \
    '# a comment mentioning workspace is fine' \
    '  _sanitize_workspace_name "$1"' \
    '  ConvertTo-WorkspaceName "$1"' \
    '  local workspace_name="x"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 3: bare curl (the TLS floor) ────────────────────────────────────────

@test "rule 3: a bare curl call is caught" {
  fixture '  curl -fsSL "$url" -o "$out"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"bare 'curl'"* ]] || return 1
}

@test "rule 3: curl_secure is NOT a bare curl (\\bcurl\\b must not match the wrapper)" {
  # The whole point of the rule is to push call sites onto the wrapper; flagging
  # the wrapper would make the rule unsatisfiable.
  fixture \
    '  curl_secure "$url" -o "$out"' \
    '  local curl_pid=$!' \
    '  nocurl=1'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 3: the documented exemptions are clean (TLS named, comment, presence test, install one-liner)" {
  fixture \
    '  curl --tlsv1.2 -fsSL "$url"' \
    '# curl in a comment is fine' \
    '  has curl || return 1' \
    '  command -v curl >/dev/null' \
    '  echo "  curl -fsSL https://tracebloc.io/i.sh | sh"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── rule 4: capital-T 'Tracebloc' ────────────────────────────────────────────
# Note this is the FOURTH rule; the header comment called it "Three mechanical
# checks" until backend#1924, which is why it is worth a test of its own.

@test "rule 4: capital-T 'Tracebloc' in user-facing text is caught" {
  fixture '  echo "Welcome to Tracebloc"'
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"capital-T 'Tracebloc'"* ]] || return 1
}

@test "rule 4: lowercase product name is clean" {
  fixture '  echo "Welcome to tracebloc"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 4: PascalCase identifiers and comments are exempt" {
  # Two DIFFERENT exemptions live here and must be driven separately, or one of
  # them is untested: `Tracebloc[A-Z]` spares a name with a following capital,
  # `[-]Tracebloc` spares a cmdlet name with a leading dash. Found by mutation —
  # a fixture of only `Get-TraceblocClientEnv` satisfies BOTH, so deleting the
  # dash filter changed nothing and the test stayed green.
  fixture \
    '# Tracebloc in a comment is fine' \
    '  $key = "TraceblocInstallerResume"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "rule 4: a cmdlet name with NO following capital is exempt via the leading dash alone" {
  # `Get-Tracebloc` — the one input that only `[-]Tracebloc` can spare.
  fixture '  Get-Tracebloc "$1"'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── the opt-out marker ───────────────────────────────────────────────────────
# The header promises it works on ANY check. Tested per rule, because the marker
# is applied in one shared place (scan) and a regression would silently un-exempt
# every deliberate edge in the tree at once.

@test "the '# style-guard: allow' marker opts a line out of EVERY rule" {
  fixture \
    '  local c="#01a5cc"   # style-guard: allow' \
    '  echo "your workspace"   # style-guard: allow' \
    '  curl -fsSL "$url"   # style-guard: allow' \
    '  echo "Tracebloc"   # style-guard: allow'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "the marker is not required to be spaced exactly (#style-guard:allow also opts out)" {
  fixture '  echo "your workspace"   #style-guard:allow'
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── scope: what the scanner does and does not read ───────────────────────────

@test "scope: violations in scripts/tests/ are not scanned (fixtures must not self-trip the gate)" {
  printf '  echo "your workspace"\n' > "$WORK/scripts/tests/zz-scope-fixture.sh"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

@test "scope: .ps1 files ARE scanned (the gate is cross-platform, not bash-only)" {
  printf '  Write-Host "your workspace"\n' > "$WORK/scripts/zz-fixture.ps1"
  run run_style
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"banned term 'workspace'"* ]] || return 1
}

@test "scope: non-script files are not scanned" {
  printf 'your workspace\n' > "$WORK/scripts/zz-fixture.md"
  run run_style
  [ "$status" -eq 0 ] || return 1
}

# ── fail-closed ──────────────────────────────────────────────────────────────
# The script's own comment: "a mis-run guard (wrong dir, missing tree) must never
# look like a pass". Exit 2 is reserved for that, and is distinct from exit 1.

@test "fail-closed: no scripts/ tree -> exit 2, not a clean 0" {
  local lone="$WORK/lone"
  mkdir -p "$lone/scripts"
  cp "$CS" "$lone/scripts/check-style.sh"
  rm -rf "$lone/scripts"          # the script is gone with it; run the copy by path
  mkdir -p "$lone/bin"
  cp "$CS" "$lone/bin/check-style.sh"
  run bash "$lone/bin/check-style.sh"
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"refusing to report clean"* ]] || return 1
}

@test "fail-closed: a grep internal error -> exit 2, not a clean 0" {
  # The `rc >= 2` branch in scan(). Driven by putting a grep that exits 2 on PATH,
  # so the REAL branch runs — rather than editing the script, which would test a
  # copy of the rule instead of the rule (backend#1729 rule 9).
  local stub="$WORK/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/grep"
  chmod +x "$stub/grep"
  run env PATH="$stub:$PATH" bash -c "cd '$WORK' && bash scripts/check-style.sh"
  [ "$status" -eq 2 ] || return 1
}

@test "exit codes are distinct: 1 means violations, 2 means the guard could not tell" {
  fixture '  echo "your workspace"'
  run run_style
  [ "$status" -eq 1 ] || return 1        # a real violation is 1, never 2
  [[ "$output" != *"failing closed"* ]] || return 1
}

# ── the header's own claim ───────────────────────────────────────────────────

@test "the header's rule count matches the rules actually implemented" {
  # backend#1924 found this stale: the header said "Three mechanical checks"
  # while four `report` calls were live. A gate whose own description undercounts
  # it is how a rule gets dropped without anyone noticing.
  local implemented declared
  implemented="$(grep -c '^report ' "$CS")"
  declared="$(grep -oE '^#  (Three|Four|Five|Six) mechanical checks' "$CS" | awk '{print $2}')"
  case "$declared" in
    Three) declared=3 ;; Four) declared=4 ;; Five) declared=5 ;; Six) declared=6 ;;
    *) return 1 ;;                       # unparsed header is a finding, not a pass
  esac
  [ "$implemented" -eq "$declared" ] || return 1
}
