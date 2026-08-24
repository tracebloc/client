#!/usr/bin/env bats
# The k3s-components agreement guard, tested (client#764).
#
# WHY THIS EXISTS
# ---------------
# The guard is registered in the Makefile's DRIFT_GUARDS and therefore runs in
# `Source-of-truth drift`, a REQUIRED check. It had no test of its own: the only
# thing exercising it was itself, against the real tree, where it prints "green".
# A required gate whose only evidence is its own green run is the shape this repo
# keeps finding (backend#1729).
#
# Every case drives the REAL script via TB_K3S_AGREEMENT_ROOT — never a copy of
# its rules. An inline re-implementation drifts from production and then proves
# that a regex nobody runs would have caught the bug (#1729 rule 9).
#
# Exit codes are the guard's contract: 0 clean, 1 disagreement, 2 cannot tell.

setup() {
  GUARD="${BATS_TEST_DIRNAME}/k3s-components-agreement.sh"
  ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/k3sagree.XXXXXX")"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/client/templates"
}

teardown() { [ -n "${ROOT:-}" ] && [ -d "$ROOT" ] && rm -rf "$ROOT"; return 0; }

# The three files the guard reads. Defaults are the AGREEING, coupled state, so
# each test mutates exactly the one thing it is about.
write_bash() {
  local set_="${1:-traefik servicelb local-storage}"
  { echo '_create_new_cluster() {'
    for c in $set_; do echo "      --k3s-arg \"--disable=${c}@server:*\" \\"; done
    echo '}'; } > "$ROOT/scripts/lib/cluster.sh"
}
write_ps1() {
  local set_="${1:-traefik servicelb local-storage}"
  { echo '$k3dArgs = @('
    for c in $set_; do echo "      \"--k3s-arg\", \"--disable=${c}@server:*\","; done
    echo ')'; } > "$ROOT/scripts/install-k8s.ps1"
}
# $1 = comment opener ({{/* or {{- /*), $2 = "code" to include code, else omitted.
# Pass '' for $1 to take the default opener with a non-default mode.
#
# The default is the PLAIN spelling `{{/*`, and it is emitted LITERALLY. It was
# written `"${1:-\{\{/\*}"`, and bash keeps those backslashes inside double
# quotes, so the fixture carried a 7-byte `\{\{/\*` line instead — a string the
# stripper's opener cannot match, in which `{{` never even appears adjacently.
# Every default-opener case therefore ran against a file nothing was stripped
# from: the poison prose below stayed in ds_body and satisfied check 3 on its
# own, so the lookup and fail it merely describes never had to be there
# (client#788; the unreachable-fixture + redundant-mechanism pair in
# .cursor/BUGBOT.md). Keep this single-quoted — a backslash here silently
# disarms every default-opener case below.
write_ds() {
  local opener="${1-}" mode="${2:-code}"
  [ -n "$opener" ] || opener='{{/*'
  { printf '%s\n' "$opener"
    echo '  Pre-flight prose naming v1beta1.metrics.k8s.io and saying it will fail hard.'
    echo '*/}}'
    if [ "$mode" = code ]; then
      echo '{{- $metrics := lookup "apiregistration.k8s.io/v1" "APIService" "" "v1beta1.metrics.k8s.io" -}}'
      echo '{{- fail "resourceMonitor is enabled but metrics.k8s.io is absent." -}}'
    fi
    echo 'apiVersion: apps/v1'; } > "$ROOT/client/templates/resource-monitor-daemonset.yaml"
}
run_guard() { TB_K3S_AGREEMENT_ROOT="$ROOT" run bash "$GUARD"; }

# A daemonset whose coupling sits BELOW a chomped comment block that closes with
# `*/ -}}` — the form the real template uses and the fixtures above do not.
# A stripper that opens on `{{- /*` but cannot close on `*/ -}}` swallows the
# rest of the file, so the code below is invisible and the guard false-FAILS.
write_ds_code_below_chomped_block() {
  { echo '{{- /* leading prose, chomped both ends, closing with a space before the hyphen'
    echo '     and saying nothing the checks grep for. */ -}}'
    echo '{{- $metrics := lookup "apiregistration.k8s.io/v1" "APIService" "" "v1beta1.metrics.k8s.io" -}}'
    echo '{{- fail "resourceMonitor is enabled but metrics.k8s.io is absent." -}}'
    echo 'apiVersion: apps/v1'; } > "$ROOT/client/templates/resource-monitor-daemonset.yaml"
}

# ── the happy path, so every "catches X" below means something ───────────────
#
# This is the GREEN half of the default-opener pair: with the block actually
# stripped, the lookup and the fail below it are the only things left that can
# satisfy check 3. It reddens if the stripper over-strips and eats them; its
# red sibling, further down, is what reddens if the strip stops happening.

@test "agreeing installers with the coupling intact exit 0" {
  write_bash; write_ps1; write_ds
  run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── disagreement between the two installers ──────────────────────────────────

@test "catches a component disabled in bash but not in ps1" {
  write_bash "traefik servicelb local-storage"; write_ps1 "traefik servicelb"; write_ds
  run_guard
  [ "$status" -eq 1 ] || return 1
}

@test "catches a component disabled in ps1 but not in bash" {
  write_bash "traefik servicelb"; write_ps1 "traefik servicelb local-storage"; write_ds
  run_guard
  [ "$status" -eq 1 ] || return 1
}

@test "catches metrics-server disabled in EITHER installer (the load-bearing one)" {
  write_bash "traefik servicelb local-storage metrics-server"
  write_ps1  "traefik servicelb local-storage metrics-server"
  write_ds
  run_guard
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"metrics-server"* ]] || return 1
}

# ── the coupling that makes check 2 worth having ─────────────────────────────
#
# Each opener spelling is exercised as a PAIR, and only the pair says anything
# about the strip. Stripping only ever REMOVES lines, and every check-3 finding
# fires on an ABSENCE, so an under-stripping stripper can only ever turn a
# finding into a pass: the green half of a pair cannot see one, no matter what
# it asserts. The red half — poison prose present, coupling deleted — is the
# half that reddens when the opener stops matching, because the prose then
# stands in for the code it merely describes. The green half covers the opposite
# failure, an over-stripping stripper that eats the code below the block
# (client#764). Neither half alone is a test of the stripper.

# The fixture's own quoting, asserted directly rather than assumed: the pattern
# below is written out here independently of write_ds, so a re-escaped opener
# cannot agree with itself (backend#1729 rule 9).
@test "the default opener reaches the stripper: a literal {{/* line, no backslashes" {
  local ds
  write_ds
  ds="$ROOT/client/templates/resource-monitor-daemonset.yaml"
  grep -qxF '{{/*' "$ds" || {
    echo "the default fixture's opener is not a literal {{/*, so the stripper cannot match it:"
    sed -n '1p' "$ds"
    return 1
  }
}

@test "catches the chart no longer looking up the APIService (default opener {{/*)" {
  write_bash; write_ps1; write_ds '' nocode
  run_guard
  [ "$status" -eq 1 ] || { echo "FAIL-OPEN: the prose satisfied check 3"; echo "$output"; return 1; }
  # Which refusal, not just that one happened: exit 1 is also how a disagreeing
  # pair of installers reports, and that is not what this case is about
  # (backend#1729 rule 10).
  [[ "$output" == *"no longer looks up v1beta1.metrics.k8s.io"* ]] || {
    echo "exit 1, but not for the missing coupling:"; echo "$output"; return 1; }
}

# THE BUGBOT REGRESSION (client#764). Same removal, but the header comment uses
# Helm's whitespace-chomping opener `{{- /*`. Before the fix the stripper only
# matched `{{/*`, so the prose stayed in ds_body and could stand in for the code
# it merely describes — a required guard passing on its own documentation.
@test "and still catches it when the header uses the chomping opener {{- /*" {
  write_bash; write_ps1; write_ds '{{- /*' nocode
  run_guard
  [ "$status" -eq 1 ] || { echo "FAIL-OPEN: prose satisfied the check"; echo "$output"; return 1; }
  [[ "$output" == *"no longer looks up v1beta1.metrics.k8s.io"* ]] || {
    echo "exit 1, but not for the missing coupling:"; echo "$output"; return 1; }
}

@test "the chomping opener does not break the CLEAN case either" {
  write_bash; write_ps1; write_ds '{{- /*' code
  run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── fail closed, per the guard's own contract ────────────────────────────────

@test "an unreadable installer is 'cannot tell' (exit 2), never green" {
  write_bash; write_ps1; write_ds
  rm -f "$ROOT/scripts/install-k8s.ps1"
  run_guard
  [ "$status" -eq 2 ] || return 1
}

@test "an unreadable daemonset is 'cannot tell' (exit 2), never green" {
  write_bash; write_ps1; write_ds
  rm -f "$ROOT/client/templates/resource-monitor-daemonset.yaml"
  run_guard
  [ "$status" -eq 2 ] || return 1
}

# Bugbot, client#764: opener and closer are ONE change. Teaching the opener
# `{{- /*` without teaching the closer `*/ -}}` meant a block that used both
# never terminated, and the stripper ate the rest of the file — measured on the
# real template, 80 of 165 lines survived instead of 103. It passed only because
# the coupling happens to sit ABOVE that block. This fixture puts it below,
# which is the arrangement that exposes it.
@test "code below a chomped block closing '*/ -}}' is still seen (not eaten)" {
  write_bash; write_ps1; write_ds_code_below_chomped_block
  run_guard
  [ "$status" -eq 0 ] || { echo "FALSE FAIL: the stripper ate the coupling"; echo "$output"; return 1; }
}

# ...and the mirror, so the case above cannot pass by the guard going blind:
# with the code genuinely absent below such a block, it must STILL be caught.
@test "and its absence below that same block is still caught" {
  write_bash; write_ps1
  { echo '{{- /* leading prose, chomped both ends, closing with a space before the hyphen'
    echo '     and saying nothing the checks grep for. */ -}}'
    echo 'apiVersion: apps/v1'; } > "$ROOT/client/templates/resource-monitor-daemonset.yaml"
  run_guard
  [ "$status" -eq 1 ] || return 1
}
