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

# _depname — echo the Deployment name from a `kubectl get deployment <name> …`
# argv, so a kubectl mock can answer per-workload (flip one deployment down).
_depname() {
  local a prev=""
  for a in "$@"; do
    [ "$prev" = deployment ] && { printf '%s' "$a"; return 0; }
    prev="$a"
  done
}

# ── _assess_cluster_servers_running (read-only serversRunning, jq-free) ──────
# Single jq-free path (jq is not a guaranteed installer prerequisite, Bugbot
# #284): the k3d table's SERVERS column ("running/total"), read with awk.
@test "_assess_cluster_servers_running: running cluster -> >=1" {
  k3d() { printf 'tracebloc 1/1 0/0\n'; }
  run _assess_cluster_servers_running
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "_assess_cluster_servers_running: stopped cluster -> 0" {
  k3d() { printf 'tracebloc 0/1 0/0\n'; }
  run _assess_cluster_servers_running
  [ "$output" = "0" ]
}

@test "_assess_cluster_servers_running: k3d error -> 0 (never non-numeric)" {
  k3d() { return 1; }
  run _assess_cluster_servers_running
  [ "$output" = "0" ]
}

# ── _assess_workload_ready (ALL shared workloads; bounded, read-only) ───────
# "Ready" must match the installer's OWN definition — the same deployment set
# wait_for_client_ready uses (mysql-client + ${ns}-jobs-manager +
# ${ns}-requests-proxy). These tests are mutation-real against the old
# jobs-manager-only probe: "mysql-client down" / "requests-proxy down" both
# return ready under the old code (it never looked at them), so they'd fail it.
@test "_assess_workload_ready: all three Ready -> ready (0)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { echo 1; }                          # every workload reports 1 ready
  run _assess_workload_ready tracebloc
  [ "$status" -eq 0 ]
}

@test "_assess_workload_ready: mysql-client down -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in mysql-client) echo "";; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: jobs-manager has 0 ready -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-jobs-manager) echo 0;; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: requests-proxy down (training egress) -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) echo "";; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: a deployment absent (kubectl errors) -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) return 1;; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: kubectl absent -> not ready (1)" {
  has() { return 1; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: empty namespace -> not ready (1)" {
  has() { return 0; }
  run _assess_workload_ready ""
  [ "$status" -ne 0 ]
}

@test "_assess_workload_ready: probes ALL three, each with a bounded --request-timeout" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { printf '%s | %s\n' "$(_depname "$@")" "$*" >>"$MOCK_CALLS"; echo 1; }
  run _assess_workload_ready tracebloc
  [ "$status" -eq 0 ]
  run mock_calls
  assert_has "mysql-client" "$output"
  assert_has "tracebloc-jobs-manager" "$output"
  assert_has "tracebloc-requests-proxy" "$output"
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

# healthy requires ALL three workloads: with the REAL _assess_workload_ready
# driven per-deployment, one workload down at the classify level -> degraded.
@test "_assess_classify: one workload down (requests-proxy) -> degraded (workload-not-ready)" {
  has() { return 0; }                            # k3d, kubectl, tracebloc present
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_cli_present() { return 0; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) echo "";; *) echo 1;; esac; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ]
  [ "$INSTALL_STATE_REASON" = workload-not-ready ]
}

@test "_assess_classify: up + all workloads Ready but CLI missing -> degraded (cli-missing)" {
  has() { case "$1" in tracebloc) return 1;; *) return 0;; esac; }   # k3d+kubectl present, CLI absent
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  kubectl() { echo 1; }                          # all workloads Ready
  HOME="$BATS_TEST_TMPDIR/nocli"; mkdir -p "$HOME"   # and no ~/.local/bin/tracebloc
  _assess_classify
  [ "$INSTALL_STATE" = degraded ]
  [ "$INSTALL_STATE_REASON" = cli-missing ]
}

@test "_assess_classify: all signals true (all three workloads Ready + CLI) -> healthy" {
  has() { return 0; }                            # k3d, kubectl, tracebloc all present
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=munich; }
  _assess_cluster_servers_running() { echo 1; }
  kubectl() { echo 1; }                          # every workload Ready
  _assess_classify
  [ "$INSTALL_STATE" = healthy ]
  assert_has "munich" "$INSTALL_STATE_REASON"
}

# ── _assess_handoff (hand-off + exit 0, no exec) ────────────────────────────
# main() has already run setup_log_file (`exec > >(tee …) 2>&1`), so the hand-off
# must give the interactive home screen a REAL terminal on ALL THREE streams, not
# just stdin (Bugbot: "Handoff loses terminal stdout"). TB_TTY points at a temp
# file here so we can prove tracebloc's stdout is redirected to the terminal —
# it lands in the file, NOT the (teed) script stdout.
@test "_assess_handoff: openable tty -> routes the home screen to the terminal, exit 0" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HOME_SCREEN"; }        # writes to whatever stdout it's given
  TB_TTY="$BATS_TEST_TMPDIR/tty"; : > "$TB_TTY"
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"   # the success line: script stdout
  assert_has "HOME_SCREEN" "$(cat "$TB_TTY")"             # home screen: the terminal, not the pipe
  refute_has "HOME_SCREEN" "$output"                      # proves stdout was redirected off the pipe
}

@test "_assess_handoff: hands off with NO args (bare = the home screen)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "ARGS=[$*]"; }
  TB_TTY="$BATS_TEST_TMPDIR/tty"; : > "$TB_TTY"
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "ARGS=[]" "$(cat "$TB_TTY")"      # invoked bare, not a subcommand
}

@test "_assess_handoff: unopenable tty -> falls back to </dev/null, still exit 0" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HOME_SCREEN"; }
  TB_TTY="$BATS_TEST_TMPDIR/nope/tty"          # parent dir absent -> not openable
  run _assess_handoff
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$output"           # fallback leaves stdout on the (captured) pipe
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
  TB_TTY="$BATS_TEST_TMPDIR/tty"; : > "$TB_TTY"
  run assess_existing_install
  [ "$status" -eq 0 ]
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$(cat "$TB_TTY")"
}

# Mutation guard for the short-circuit: if the healthy branch stops handing off
# (e.g. mutated to a bare `return 0`), HOME_SCREEN disappears and this fails.
@test "assess_existing_install: healthy MUST hand off (short-circuit mutation guard)" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON="ns:x"; }
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HANDED_OFF"; }
  TB_TTY="$BATS_TEST_TMPDIR/nope/tty"          # unopenable -> fallback keeps stdout captured
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
