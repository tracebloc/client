#!/usr/bin/env bats
# Tests for scripts/lib/assess.sh — the installer "stop-and-check" gate.
#
# The load-bearing properties:
#   • classification is READ-ONLY and CERTAIN — "healthy" requires ALL of:
#       cluster running AND a tracebloc release present AND jobs-manager Ready
#       AND the CLI present. Anything less is fresh or degraded and falls through.
#   • on uncertainty it degrades toward the normal flow — never a false healthy.
#   • a healthy machine short-circuits: hand off to `tracebloc` (bare = the home
#     screen), then exit 0 (never `exec`, so the EXIT trap still cleans up).
#   • --force / TB_FORCE_REINSTALL bypasses the gate entirely.
#
# macOS-bats blindspot: local bash 3.2 can SILENTLY PASS a failing bare `[[ … ]]`
# used as a test's last statement. So every content assertion goes through the
# grep-backed assert_has / refute_has helpers below (grep's exit status + an
# explicit `return 1` are honored on every bash), and status checks use single-
# bracket `[ … ]`. Linux CI is the authority; these helpers make local runs
# fail loudly instead of vacuously.
load test_helper

setup() {
  load_lib cluster.sh                          # common.sh + cluster.sh (_cluster_exists)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/install-client-helm.sh"   # detect_installed_client
  # shellcheck source=/dev/null
  source "${LIB_DIR}/assess.sh"                # the unit under test
  MOCK_CALLS="$(mktemp)"
  CLUSTER_NAME=tracebloc
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  # A clean slate: no force flag, and INSTALL_STATE unset so a test can't pass on
  # a value left by an earlier one.
  unset TB_FORCE_REINSTALL TRACEBLOC_FORCE_REINSTALL INSTALL_STATE INSTALL_STATE_REASON
}

# fail-loud assertions (see the blindspot note above)
assert_has() {   # needle haystack
  printf '%s\n' "$2" | grep -qF -- "$1" && return 0
  printf 'ASSERT FAIL: expected to find >>%s<<\n--- in ---\n%s\n' "$1" "$2" >&2
  return 1
}
refute_has() {   # needle haystack
  if printf '%s\n' "$2" | grep -qF -- "$1"; then
    printf 'REFUTE FAIL: did NOT expect >>%s<<\n--- in ---\n%s\n' "$1" "$2" >&2
    return 1
  fi
  return 0
}

# ── _assess_cluster_servers_running (read-only serversRunning, jq + awk) ─────
# The k3d mock answers BOTH the jq path (`-o json`) and the awk path
# (`--no-headers`) so the result is identical whether or not the runner has jq.
@test "_assess_cluster_servers_running: running cluster -> >=1 (jq and awk paths agree)" {
  k3d() {
    case "$*" in
      *"-o json"*)      printf '[{"name":"tracebloc","serversRunning":1}]\n' ;;
      *"--no-headers"*) printf 'tracebloc 1/1 0/0\n' ;;
      *)                printf 'tracebloc 1/1 0/0\n' ;;
    esac
  }
  run _assess_cluster_servers_running
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "_assess_cluster_servers_running: stopped cluster -> 0" {
  k3d() {
    case "$*" in
      *"-o json"*)      printf '[{"name":"tracebloc","serversRunning":0}]\n' ;;
      *"--no-headers"*) printf 'tracebloc 0/1 0/0\n' ;;
      *)                printf 'tracebloc 0/1 0/0\n' ;;
    esac
  }
  run _assess_cluster_servers_running
  [ "$output" = "0" ]
}

@test "_assess_cluster_servers_running: k3d error -> 0 (never non-numeric)" {
  k3d() { return 1; }
  run _assess_cluster_servers_running
  [ "$output" = "0" ]
}

# ── _assess_jobs_manager_ready (bounded, read-only) ─────────────────────────
@test "_assess_jobs_manager_ready: readyReplicas>=1 -> ready (0)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { echo 2; }
  run _assess_jobs_manager_ready tracebloc
  [ "$status" -eq 0 ]
}

@test "_assess_jobs_manager_ready: empty readyReplicas -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { echo ""; }
  run _assess_jobs_manager_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_jobs_manager_ready: kubectl error -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { return 1; }
  run _assess_jobs_manager_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_jobs_manager_ready: kubectl absent -> not ready (1)" {
  has() { return 1; }
  run _assess_jobs_manager_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_jobs_manager_ready: empty namespace -> not ready (1)" {
  has() { return 0; }
  run _assess_jobs_manager_ready ""
  [ "$status" -ne 0 ]
}

@test "_assess_jobs_manager_ready: passes a bounded --request-timeout (can't hang)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { printf '%s\n' "$*" >>"$MOCK_CALLS"; echo 1; }
  run _assess_jobs_manager_ready tracebloc
  [ "$status" -eq 0 ]
  run mock_calls
  assert_has "--request-timeout=" "$output"
}

# ── _assess_cli_present ──────────────────────────────────────────────────────
@test "_assess_cli_present: on PATH -> present (0)" {
  has() { [ "$1" = tracebloc ]; }
  run _assess_cli_present
  [ "$status" -eq 0 ]
}

@test "_assess_cli_present: only in ~/.local/bin -> present (0)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/h"; mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/tracebloc"; chmod +x "$HOME/.local/bin/tracebloc"
  run _assess_cli_present
  [ "$status" -eq 0 ]
}

@test "_assess_cli_present: absent everywhere -> not present (1)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/empty"; mkdir -p "$HOME"
  run _assess_cli_present
  [ "$status" -ne 0 ]
}

# ── _assess_classify (decision logic; leaf probes forced) ───────────────────
@test "_assess_classify: no k3d / no cluster -> fresh (no-cluster)" {
  has() { return 1; }                          # no k3d
  _cluster_exists() { return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = fresh ]
  [ "$INSTALL_STATE_REASON" = no-cluster ]
}

@test "_assess_classify: cluster but no tracebloc release -> fresh (cluster-no-release)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; }
  _assess_classify
  [ "$INSTALL_STATE" = fresh ]
  [ "$INSTALL_STATE_REASON" = cluster-no-release ]
}

@test "_assess_classify: release present but cluster stopped -> degraded (cluster-stopped)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 0; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ]
  [ "$INSTALL_STATE_REASON" = cluster-stopped ]
}

@test "_assess_classify: running but workload not Ready -> degraded (workload-not-ready)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_jobs_manager_ready() { return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ]
  [ "$INSTALL_STATE_REASON" = workload-not-ready ]
}

@test "_assess_classify: up + Ready but CLI missing -> degraded (cli-missing)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_jobs_manager_ready() { return 0; }
  _assess_cli_present() { return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ]
  [ "$INSTALL_STATE_REASON" = cli-missing ]
}

@test "_assess_classify: all four signals true -> healthy" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=munich; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_jobs_manager_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_classify
  [ "$INSTALL_STATE" = healthy ]
  assert_has "munich" "$INSTALL_STATE_REASON"
}

# ── _assess_handoff (hand-off + exit 0, no exec) ────────────────────────────
@test "_assess_handoff: resolvable CLI -> prints the line, runs tracebloc, exit 0" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HOME_SCREEN"; }
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$output"
}

@test "_assess_handoff: hands off with NO args (bare = the home screen)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "ARGS=[$*]"; }
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "ARGS=[]" "$output"               # invoked bare, not a subcommand
}

@test "_assess_handoff: unresolvable CLI -> honest fallback, still exit 0" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/emptyhome"; mkdir -p "$HOME"
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"
  assert_has "tracebloc" "$output"             # tells the user the command to run
}

# ── assess_existing_install (the gate main() calls) ─────────────────────────
@test "assess_existing_install: healthy -> hands off to the home screen, exit 0" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON="ns:munich"; }
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$output"
}

# Mutation guard for the short-circuit: if the healthy branch stops handing off
# (e.g. mutated to a bare `return 0`), HOME_SCREEN disappears and this fails.
@test "assess_existing_install: healthy MUST hand off (short-circuit mutation guard)" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON="ns:x"; }
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HANDED_OFF"; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "HANDED_OFF" "$output"
}

@test "assess_existing_install: --force / TB_FORCE_REINSTALL bypasses the gate (no classify, no hand-off)" {
  TB_FORCE_REINSTALL=1
  _assess_classify() { echo "CLASSIFY_RAN"; INSTALL_STATE=healthy; }   # must NOT run
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  refute_has "CLASSIFY_RAN" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: degraded (stopped) -> honest line, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cluster-stopped; }
  tracebloc() { echo "HOME_SCREEN"; }          # must NOT be called on a fall-through
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "secure environment is stopped" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: degraded (cli-missing) -> names the CLI, returns 0" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cli-missing; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "CLI isn't installed" "$output"
}

@test "assess_existing_install: degraded says 'secure environment', never 'client'" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=workload-not-ready; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "secure environment" "$output"
  refute_has "client" "$output"
}

@test "assess_existing_install: fresh (no cluster) -> first-time header, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=fresh; INSTALL_STATE_REASON=no-cluster; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "first time" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: fresh (cluster, no release) -> quiet, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=fresh; INSTALL_STATE_REASON=cluster-no-release; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ]
  refute_has "first time" "$output"            # no ceremony when a cluster already exists
  refute_has "HOME_SCREEN" "$output"
}
