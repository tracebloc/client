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
# $1 = comment opener ({{/* or {{- /*), $2 = "code" to include code, else omitted
write_ds() {
  local opener="${1:-\{\{/\*}" mode="${2:-code}"
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

# ── the happy path, so every "catches X" below means something ───────────────

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

@test "catches the chart no longer looking up the APIService" {
  write_bash; write_ps1; write_ds '{{/*' nocode
  run_guard
  [ "$status" -eq 1 ] || return 1
}

# THE BUGBOT REGRESSION (client#764). Same removal, but the header comment uses
# Helm's whitespace-chomping opener `{{- /*`. Before the fix the stripper only
# matched `{{/*`, so the prose stayed in ds_body and could stand in for the code
# it merely describes — a required guard passing on its own documentation.
@test "and still catches it when the header uses the chomping opener {{- /*" {
  write_bash; write_ps1; write_ds '{{- /*' nocode
  run_guard
  [ "$status" -eq 1 ] || { echo "FAIL-OPEN: prose satisfied the check"; echo "$output"; return 1; }
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
