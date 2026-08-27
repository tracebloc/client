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
bats_require_minimum_version 1.7.0   # `run -<code>` flags
load test_helper

setup() {
  load_lib cluster.sh                          # common.sh + cluster.sh (_cluster_exists)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/install-client-helm.sh"   # detect_installed_client
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"           # _try_start_docker_desktop (sourced before assess.sh in install-k8s.sh)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/assess.sh"                # the unit under test
  MOCK_CALLS="$(mktemp)"
  CLUSTER_NAME=tracebloc
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  # A clean slate: no force flag, and INSTALL_STATE unset so a test can't pass on
  # a value left by an earlier one.
  unset TB_FORCE_REINSTALL TRACEBLOC_FORCE_REINSTALL INSTALL_STATE INSTALL_STATE_REASON
  # backend#2253 explicit-upgrade signals — cleared so a leak from the caller's
  # shell (or an earlier test) can't turn an ordinary classify test into an
  # upgrade one, and vice-versa.
  unset TB_UPGRADE_CLI TB_CLI_LATEST
  # Leaf probe added in client#682, forced here for the same reason as the other
  # leaf probes: the classify tests below exercise cluster/release/workload
  # decision logic and must not depend on whether a real docker answers on the
  # machine running bats. The runtime-down tests override it explicitly.
  _assess_runtime_down() { return 1; }
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
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "1" ] || return 1
}

@test "_assess_cluster_servers_running: stopped cluster -> 0" {
  k3d() { printf 'tracebloc 0/1 0/0\n'; }
  run _assess_cluster_servers_running
  [ "$output" = "0" ] || return 1
}

@test "_assess_cluster_servers_running: k3d error -> 0 (never non-numeric)" {
  k3d() { return 1; }
  run _assess_cluster_servers_running
  [ "$output" = "0" ] || return 1
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
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_workload_ready: mysql-client down -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in mysql-client) echo "";; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: jobs-manager has 0 ready -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-jobs-manager) echo 0;; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: requests-proxy down (training egress) -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) echo "";; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: a deployment absent (kubectl errors) -> not ready (1)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) return 1;; *) echo 1;; esac; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: kubectl absent -> not ready (1)" {
  has() { return 1; }
  run _assess_workload_ready tracebloc
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: empty namespace -> not ready (1)" {
  has() { return 0; }
  run _assess_workload_ready ""
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_workload_ready: probes ALL three, each with a bounded --request-timeout" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { printf '%s | %s\n' "$(_depname "$@")" "$*" >>"$MOCK_CALLS"; echo 1; }
  run _assess_workload_ready tracebloc
  [ "$status" -eq 0 ] || return 1
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
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_cli_present: only in ~/.local/bin -> present (0)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/h"; mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/tracebloc"; chmod +x "$HOME/.local/bin/tracebloc"
  run _assess_cli_present
  [ "$status" -eq 0 ] || return 1
}

# ── CLI version floor (client#707) ──────────────────────────────────────────
# The healthy fast-path used to pin a user to whatever CLI they first installed,
# forever: presence was checked, version never was. The cluster auto-upgrades
# hourly around a host binary nothing touches — a field machine sat on v0.5.1
# for five weeks that way.
@test "_version_lt: orders dotted versions, including the 2-vs-10 trap" {
  _version_lt 0.5.1 0.10.0  || return 1     # the field case
  _version_lt 0.9.9 0.10.0  || return 1     # 9 < 10, not a string compare
  _version_lt 0.10.0 0.10.1 || return 1
  _version_lt 0.10 0.10.1   || return 1     # missing component reads as 0
  ! _version_lt 0.10.0 0.10.0 || return 1   # equal is not less
  ! _version_lt 0.10.5 0.10.0 || return 1
  ! _version_lt 1.0.0 0.10.0 || return 1
  _version_lt 0.10.0-rc.1 0.10.0 && return 1  # pre-release compares as its base
  return 0
}

@test "_assess_cli_outdated: a CLI below the floor is outdated" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.5.1 (darwin/arm64)"; }
  run _assess_cli_outdated
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_cli_outdated: a CLI at the floor is NOT outdated" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.0 (darwin/arm64)"; }
  run _assess_cli_outdated
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_cli_outdated: a CLI above the floor is NOT outdated" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.6 (darwin/arm64)"; }
  run _assess_cli_outdated
  [ "$status" -ne 0 ] || return 1
}

# Fail OPEN: an unreadable version is not evidence of staleness, and treating it
# as outdated would reinstall the CLI on EVERY run.
@test "_assess_cli_outdated: unreadable version -> treated as current (no churn)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc (unknown build)"; }
  run _assess_cli_outdated
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_cli_outdated: a CLI that errors on 'version' -> treated as current" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { return 1; }
  run _assess_cli_outdated
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_cli_outdated: no CLI at all -> not 'outdated' (cli-missing owns that)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/empty"; mkdir -p "$HOME"
  run _assess_cli_outdated
  [ "$status" -ne 0 ] || return 1
}

# ── CLI behind latest, for an explicit `tracebloc upgrade` (backend#2253) ────
# Distinct from the floor above: the floor is "below this we cannot support you"
# (mandatory reinstall), this is "something newer exists" (the nudge's meaning).
# It is INERT unless TB_UPGRADE_CLI=1, so an ordinary installer run never pays a
# "what is latest?" cost and is never reclassified by it.
@test "_assess_cli_behind_latest: inert without TB_UPGRADE_CLI (ordinary run)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }
  TB_CLI_LATEST=0.10.8                       # newer exists, but no upgrade intent
  run _assess_cli_behind_latest
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_cli_behind_latest: upgrade intent + behind latest -> behind (0)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.10.8
  run _assess_cli_behind_latest
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_cli_behind_latest: upgrade intent + already latest -> not behind (1)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.8 (darwin/arm64)"; }
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.10.8
  run _assess_cli_behind_latest
  [ "$status" -ne 0 ] || return 1           # nothing to do; healthy handoff owns it
}

@test "_assess_cli_behind_latest: the 2-vs-10 trap is a numeric compare, not string" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.8 (darwin/arm64)"; }
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.2.0       # 0.10.8 is NEWER than 0.2.0
  run _assess_cli_behind_latest
  [ "$status" -ne 0 ] || return 1           # not behind: a string compare would say 10<2
}

# Fail SAFE toward updating under an explicit upgrade: if we can't prove the CLI
# is current (no latest passed, or an unparseable one), do the update the user
# asked for rather than silently declining it — the opposite of the floor's
# fail-open, and correct here because this only runs on an explicit upgrade.
@test "_assess_cli_behind_latest: upgrade intent + latest unknown -> behind (update anyway)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }
  TB_UPGRADE_CLI=1                           # no TB_CLI_LATEST (manual paste / offline)
  run _assess_cli_behind_latest
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_cli_behind_latest: upgrade intent + unparseable latest -> behind (update anyway)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=latest      # not a version we can compare
  run _assess_cli_behind_latest
  [ "$status" -eq 0 ] || return 1
}

@test "_assess_cli_behind_latest: no CLI at all -> not behind (cli-missing owns that)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/empty"; mkdir -p "$HOME"
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.10.8
  run _assess_cli_behind_latest
  [ "$status" -ne 0 ] || return 1
}

# The regression guard: mutation-real against the pre-fix classify, which went
# straight to healthy on any CLI that merely existed.
@test "_assess_classify: a stale CLI is degraded/cli-outdated, NEVER healthy" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_release_pending() { return 1; }
  _assess_workload_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_cli_outdated() { return 0; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = cli-outdated ] || return 1
}

@test "_assess_classify: a current CLI still reaches healthy (floor doesn't over-fire)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_release_pending() { return 1; }
  _assess_workload_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_cli_outdated() { return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = healthy ] || return 1
}

# backend#2253, the classify half of the fix. Everything is healthy EXCEPT the
# CLI is above the floor but behind latest, under an explicit `tracebloc upgrade`.
# Before the fix this went straight to healthy (the no-op the ticket is about);
# now it is a DISTINCT degraded reason main() can act on. Mutation-real: drop the
# _assess_cli_behind_latest branch and this classifies healthy again.
@test "_assess_classify: upgrade intent + CLI behind latest -> degraded (cli-behind-latest)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_release_pending() { return 1; }
  _assess_workload_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_cli_outdated() { return 1; }         # above the floor
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.10.8
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }   # behind latest
  _assess_cli_bin() { printf 'tracebloc'; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = cli-behind-latest ] || return 1
}

# The regression guard: the SAME machine on an ORDINARY run (no upgrade intent)
# must still reach healthy — the new branch is inert off the explicit-upgrade
# path, so a routine re-run is unchanged and pays no "what is latest?" cost.
@test "_assess_classify: NO upgrade intent + CLI behind latest -> still healthy (branch inert)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_release_pending() { return 1; }
  _assess_workload_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_cli_outdated() { return 1; }
  TB_CLI_LATEST=0.10.8                          # newer exists, but TB_UPGRADE_CLI unset
  tracebloc() { echo "tracebloc 0.10.5 (darwin/arm64)"; }
  _assess_cli_bin() { printf 'tracebloc'; }
  _assess_classify
  [ "$INSTALL_STATE" = healthy ] || return 1
}

# The floor keeps its stricter meaning: a BELOW-floor CLI is cli-outdated (a
# mandatory full reinstall) even under an explicit upgrade — cli-behind-latest is
# ordered after the floor check, so it never masks it.
@test "_assess_classify: upgrade intent + BELOW-floor CLI -> cli-outdated (floor still wins)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_release_pending() { return 1; }
  _assess_workload_ready() { return 0; }
  _assess_cli_present() { return 0; }
  _assess_cli_outdated() { return 0; }          # below the floor
  TB_UPGRADE_CLI=1 TB_CLI_LATEST=0.10.8
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = cli-outdated ] || return 1
}

@test "assess_existing_install: cli-outdated says so, continues, and does NOT hand off" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cli-outdated; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "out of date" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "_assess_cli_present: absent everywhere -> not present (1)" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/empty"; mkdir -p "$HOME"
  run _assess_cli_present
  [ "$status" -ne 0 ] || return 1
}

# ── _assess_runtime_down (client#682) ───────────────────────────────────────
# setup() forces this leaf probe so the classify tests stay about classification.
# The tests in THIS block are about the probe itself, so they restore the real
# implementation first. Re-sourcing assess.sh is safe: the mocks these tests use
# (has / _bounded / docker) all live in common.sh, which is not re-sourced.
_use_real_runtime_probe() {
  unset -f _assess_runtime_down
  # shellcheck source=/dev/null
  source "${LIB_DIR}/assess.sh"
}

# The gate must separate "Docker isn't installed" (a genuinely fresh machine)
# from "Docker is installed but not answering" (one sentence fixes it). Before
# this both collapsed into _cluster_exists returning 1 -> fresh/no-cluster, so a
# laptop that had only to start Docker was told it had nothing installed.
@test "_assess_runtime_down: no docker binary -> NOT down (genuinely fresh)" {
  _use_real_runtime_probe
  has() { [ "$1" != docker ]; }
  run _assess_runtime_down
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_runtime_down: docker answers -> NOT down" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { shift; "$@"; }
  docker() { return 0; }
  run _assess_runtime_down
  [ "$status" -ne 0 ] || return 1
}

@test "_assess_runtime_down: daemon unreachable (Linux socket) -> down" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { shift; "$@"; }
  docker() { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; return 1; }
  run _assess_runtime_down
  [ "$status" -eq 0 ] || return 1
}

# The exact shape a stopped Docker Desktop produces on macOS.
@test "_assess_runtime_down: Docker Desktop stopped (macOS socket path) -> down" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { shift; "$@"; }
  docker() { echo "dial unix /Users/u/.docker/run/docker.sock: connect: no such file or directory" >&2; return 1; }
  run _assess_runtime_down
  [ "$status" -eq 0 ] || return 1
}

# A Linux user outside the docker group is a DIFFERENT problem with a different
# remedy — it must not be answered with "start Docker".
#
# The fixture is the REAL, FULL message, which contains a `dial unix …` clause as
# well as the permission wording (Bugbot: a shortened fixture passed vacuously
# against a version that matched the connection phrases first). Mutation-real —
# reorder the two greps in _assess_runtime_down and this fails.
@test "_assess_runtime_down: permission denied -> NOT down (different remedy)" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { shift; "$@"; }
  docker() { echo 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get "http://%2Fvar%2Frun%2Fdocker.sock/v1.47/info": dial unix /var/run/docker.sock: connect: permission denied' >&2; return 1; }
  run _assess_runtime_down
  [ "$status" -ne 0 ] || return 1
}

# The Docker Desktop / rootless variant of the same collision: "Got permission
# denied" plus a socket path. Also must NOT read as a down daemon.
@test "_assess_runtime_down: 'Got permission denied' variant -> NOT down" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { shift; "$@"; }
  docker() { echo 'Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: dial unix /var/run/docker.sock: connect: permission denied' >&2; return 1; }
  run _assess_runtime_down
  [ "$status" -ne 0 ] || return 1
}

# A daemon that will not answer inside the bound is not usable either.
@test "_assess_runtime_down: probe times out (124) -> down (wedged daemon)" {
  _use_real_runtime_probe
  has() { return 0; }
  _bounded() { return 124; }
  run _assess_runtime_down
  [ "$status" -eq 0 ] || return 1
}

# ── _assess_classify (decision logic; leaf probes forced) ───────────────────
# A down runtime makes every signal below it unknowable, so it is classified
# FIRST and the cluster probe must never run. The machine is DEGRADED, never
# fresh — "fresh" is the claim that caused client#682.
@test "_assess_classify: runtime down -> degraded (runtime-down), never fresh" {
  has() { return 0; }
  _assess_runtime_down() { return 0; }
  _cluster_exists() { touch "$BATS_TEST_TMPDIR/cluster-probed"; return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = runtime-down ] || return 1
  [ ! -f "$BATS_TEST_TMPDIR/cluster-probed" ] || return 1
}

# The regression guard for client#682: a machine with an environment it cannot
# see must never be told it has nothing. Mutation-real — reverting the classify
# order makes this fail.
@test "_assess_classify: runtime down is NOT reported as a first-time machine" {
  has() { return 0; }
  _assess_runtime_down() { return 0; }
  _cluster_exists() { return 1; }        # exactly what a down daemon looks like
  _assess_classify
  [ "$INSTALL_STATE_REASON" != no-cluster ] || return 1
}

@test "_assess_classify: no k3d / no cluster -> fresh (no-cluster)" {
  has() { return 1; }                          # no k3d
  _cluster_exists() { return 1; }
  _assess_classify
  [ "$INSTALL_STATE" = fresh ] || return 1
  [ "$INSTALL_STATE_REASON" = no-cluster ] || return 1
}

@test "_assess_classify: running cluster but no tracebloc release -> fresh (cluster-no-release)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 1; }  # running: reached only after the servers check
  detect_installed_client() { INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; }
  _assess_classify
  [ "$INSTALL_STATE" = fresh ] || return 1
  [ "$INSTALL_STATE_REASON" = cluster-no-release ] || return 1
}

@test "_assess_classify: release present but cluster stopped -> degraded (cluster-stopped)" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 0; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = cluster-stopped ] || return 1
}

# Ordering guard (Bugbot: "Assess probes Helm before cluster runs"): a stopped
# cluster must be classified cluster-stopped WITHOUT ever invoking the unbounded
# Helm probe — otherwise Helm hangs on a dead API and the box is mislabeled fresh.
@test "_assess_classify: stopped cluster short-circuits BEFORE the Helm probe" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  _assess_cluster_servers_running() { echo 0; }               # stopped
  detect_installed_client() { touch "$BATS_TEST_TMPDIR/helm-probed"; }  # must NOT run
  _assess_classify
  [ "$INSTALL_STATE_REASON" = cluster-stopped ] || return 1
  [ ! -f "$BATS_TEST_TMPDIR/helm-probed" ] || return 1                    # Helm was never touched
}

# healthy requires ALL three workloads: with the REAL _assess_workload_ready
# driven per-deployment, one workload down at the classify level -> degraded.
@test "_assess_classify: one workload down (requests-proxy) -> degraded (workload-not-ready)" {
  has() { return 0; }                            # k3d, kubectl, tracebloc present
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_release_pending() { return 1; }        # not wedged
  _assess_cli_present() { return 0; }
  kubectl() { case "$(_depname "$@")" in *-requests-proxy) echo "";; *) echo 1;; esac; }
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = workload-not-ready ] || return 1
}

@test "_assess_classify: up + all workloads Ready but CLI missing -> degraded (cli-missing)" {
  has() { case "$1" in tracebloc) return 1;; *) return 0;; esac; }   # k3d+kubectl present, CLI absent
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=tracebloc; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_release_pending() { return 1; }        # not wedged
  kubectl() { echo 1; }                          # all workloads Ready
  HOME="$BATS_TEST_TMPDIR/nocli"; mkdir -p "$HOME"   # and no ~/.local/bin/tracebloc
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = cli-missing ] || return 1
}

@test "_assess_classify: all signals true (all three workloads Ready + CLI) -> healthy" {
  has() { return 0; }                            # k3d, kubectl, tracebloc all present
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=munich; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_release_pending() { return 1; }        # not wedged
  kubectl() { echo 1; }                          # every workload Ready
  _assess_classify
  [ "$INSTALL_STATE" = healthy ] || return 1
  assert_has "munich" "$INSTALL_STATE_REASON"
}

# #554 Bugbot: a release wedged in pending-* usually still has its prior revision
# Ready, so it must NOT fast-path to healthy (which would skip recovery). It must
# degrade to the normal flow that clears the wedge.
@test "_assess_classify: release present but WEDGED in pending-* -> degraded (pending-wedge), never healthy" {
  has() { return 0; }
  _cluster_exists() { return 0; }
  detect_installed_client() { INSTALLED_CLIENT_ID=uuid; INSTALLED_CLIENT_NS=munich; }
  _assess_cluster_servers_running() { echo 1; }
  _assess_release_pending() { return 0; }        # a pending wedge is present
  _assess_cli_present() { return 0; }
  kubectl() { echo 1; }                          # prior revision's pods still Ready
  _assess_classify
  [ "$INSTALL_STATE" = degraded ] || return 1
  [ "$INSTALL_STATE_REASON" = pending-wedge ] || return 1
}

@test "_assess_release_pending: a pending release in the namespace -> true; none -> false" {
  _bounded() { shift; "$@"; }
  helm() { [ "$1" = list ] && { echo "stg"; return 0; }; return 0; }   # --pending -q lists a name
  _assess_release_pending tracebloc
  helm() { [ "$1" = list ] && return 0; return 0; }                    # no pending releases -> empty
  ! _assess_release_pending tracebloc || return 1
  ! _assess_release_pending "" || return 1                             # empty ns -> false, no helm call
}

# #554 Bugbot: the probe must NOT fail open. A helm error/timeout is uncertainty,
# and this module degrades on uncertainty (never fast-paths to a false healthy).
@test "_assess_release_pending: helm list ERROR -> treated as wedged (fail closed), not 'no wedge'" {
  _bounded() { shift; "$@"; }
  helm() { [ "$1" = list ] && return 1; return 0; }                    # probe errors / times out
  _assess_release_pending tracebloc || return 1                        # returns 0 (wedged) -> degrade
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
  [ "$status" -eq 0 ] || return 1
  assert_has "Already set up on this machine" "$output"   # the success line: script stdout
  assert_has "HOME_SCREEN" "$(cat "$TB_TTY")"             # home screen: the terminal, not the pipe
  refute_has "HOME_SCREEN" "$output"                      # proves stdout was redirected off the pipe
}

@test "_assess_handoff: hands off with NO args (bare = the home screen)" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "ARGS=[$*]"; }
  TB_TTY="$BATS_TEST_TMPDIR/tty"; : > "$TB_TTY"
  run _assess_handoff
  [ "$status" -eq 0 ] || return 1
  assert_has "ARGS=[]" "$(cat "$TB_TTY")"      # invoked bare, not a subcommand
}

@test "_assess_handoff: unopenable tty -> falls back to </dev/null, still exit 0" {
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HOME_SCREEN"; }
  TB_TTY="$BATS_TEST_TMPDIR/nope/tty"          # parent dir absent -> not openable
  run _assess_handoff
  [ "$status" -eq 0 ] || return 1
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$output"           # fallback leaves stdout on the (captured) pipe
}

@test "_assess_handoff: unresolvable CLI -> honest fallback, still exit 0" {
  has() { return 1; }
  HOME="$BATS_TEST_TMPDIR/emptyhome"; mkdir -p "$HOME"
  run _assess_handoff
  [ "$status" -eq 0 ] || return 1
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
  [ "$status" -eq 0 ] || return 1
  assert_has "Already set up on this machine" "$output"
  assert_has "HOME_SCREEN" "$(cat "$TB_TTY")"
}

# backend#2253: an explicit `tracebloc upgrade` on an otherwise-healthy box whose
# CLI is behind latest must NOT hand off (the no-op that could never clear the
# nag) and must NOT run the degraded ceremony — it returns 0 so main() runs the
# CLI-only update. This file itself performs no install (stays a read-only
# classifier); the update mutation lives in main().
@test "assess_existing_install: cli-behind-latest returns 0 without handing off or ceremony" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cli-behind-latest; }
  tracebloc() { echo "HOME_SCREEN"; }          # must NOT be launched
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  refute_has "HOME_SCREEN" "$output"           # no healthy hand-off
  refute_has "Already set up" "$output"        # nor the healthy "already set up" line
  refute_has "partly set up" "$output"         # nor the generic degraded ceremony
}

# Mutation guard for the short-circuit: if the healthy branch stops handing off
# (e.g. mutated to a bare `return 0`), HOME_SCREEN disappears and this fails.
@test "assess_existing_install: healthy MUST hand off (short-circuit mutation guard)" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON="ns:x"; }
  has() { [ "$1" = tracebloc ]; }
  tracebloc() { echo "HANDED_OFF"; }
  TB_TTY="$BATS_TEST_TMPDIR/nope/tty"          # unopenable -> fallback keeps stdout captured
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "HANDED_OFF" "$output"
}

# client#682: a down runtime is named honestly and the run CONTINUES — the normal
# flow starts Docker and reconciles. What it must never do is announce a
# first-time setup over a machine whose environment it simply could not see.
@test "assess_existing_install: runtime down -> honest line, continues, no first-time claim" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=runtime-down; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "Docker isn't running" "$output"
  refute_has "for the first time" "$output"
}

# …and it must not short-circuit to the healthy hand-off either.
@test "assess_existing_install: runtime down does not hand off to the home screen" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=runtime-down; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: --force / TB_FORCE_REINSTALL bypasses the gate (no classify, no hand-off)" {
  TB_FORCE_REINSTALL=1
  _assess_classify() { echo "CLASSIFY_RAN"; INSTALL_STATE=healthy; }   # must NOT run
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  refute_has "CLASSIFY_RAN" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: degraded (stopped) -> honest line, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cluster-stopped; }
  tracebloc() { echo "HOME_SCREEN"; }          # must NOT be called on a fall-through
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "secure environment is stopped" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: degraded (cli-missing) -> names the CLI, returns 0" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=cli-missing; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "CLI isn't installed" "$output"
}

@test "assess_existing_install: degraded says 'secure environment', never 'client'" {
  _assess_classify() { INSTALL_STATE=degraded; INSTALL_STATE_REASON=workload-not-ready; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "secure environment" "$output"
  refute_has "client" "$output"
}

@test "assess_existing_install: fresh (no cluster) -> first-time header, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=fresh; INSTALL_STATE_REASON=no-cluster; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "first time" "$output"
  refute_has "HOME_SCREEN" "$output"
}

@test "assess_existing_install: fresh (cluster, no release) -> quiet, returns 0, no hand-off" {
  _assess_classify() { INSTALL_STATE=fresh; INSTALL_STATE_REASON=cluster-no-release; }
  tracebloc() { echo "HOME_SCREEN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  refute_has "first time" "$output"            # no ceremony when a cluster already exists
  refute_has "HOME_SCREEN" "$output"
}

# ── healthy fast-path still surfaces k3s drift (#547, Bugbot #565) ───────────
# The reuse-path drift check in _handle_existing_cluster is never reached when a
# re-run classifies as healthy (it hands off + exits), so assess_existing_install
# must run the check itself before the handoff — else a healthy-but-drifted
# cluster (a client already up on a floated k3s) is silently reused.
@test "assess_existing_install: healthy branch runs the k3s drift check before handoff" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON=""; }
  _check_existing_cluster_k8s_version() { echo "DRIFT_CHECK_RAN"; }
  _assess_handoff() { echo "HANDOFF_RAN"; }        # stub: don't exit under `run`
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  assert_has "DRIFT_CHECK_RAN" "$output"
  assert_has "HANDOFF_RAN" "$output"
}

@test "assess_existing_install: --force bypass skips the drift check entirely" {
  export TB_FORCE_REINSTALL=1
  _check_existing_cluster_k8s_version() { echo "DRIFT_CHECK_RAN"; }
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  refute_has "DRIFT_CHECK_RAN" "$output"
}

# ── runtime-down: the message must not promise what the code doesn't do ──────
# This branch used to be one line:
#   info "Docker isn't running yet — starting it, then checking your environment."
# followed by `return 0`. Nothing started anything. The probe then found no
# usable runtime, macOS classified Tier 2 — the admin-password path — and the
# only `open -a Docker` in the tree sat behind that very password prompt. So a
# Mac with Docker installed but stopped could not be set up by a user who
# couldn't give an admin password, and the installer had told them it was
# starting Docker. A real customer log ended exactly there.

@test "runtime-down on macOS: actually starts Docker, and says so only when it did" {
  OS=Darwin
  _docker_app_installed() { return 0; }            # there IS an app to launch
  _try_start_docker_desktop() { return 0; }        # Docker came up
  run _assess_handle_runtime_down
  [ "$status" -eq 0 ] || return 1
  grep -qF "starting it" <<<"$output" || return 1
  grep -qF "Docker is running" <<<"$output"
}

@test "runtime-down on macOS: when the start FAILS, it says so and names the cost" {
  OS=Darwin
  _docker_app_installed() { return 0; }            # there IS an app to launch
  _try_start_docker_desktop() { return 1; }        # Docker did not come up
  run _assess_handle_runtime_down
  [ "$status" -eq 0 ] || return 1                  # never a hard gate
  # It must NOT claim success…
  ! grep -qF "Docker is running" <<<"$output" || return 1
  # …and must be explicit that the fallback path costs a password, which is the
  # thing the old copy hid.
  grep -qF "Couldn't start Docker automatically" <<<"$output" || return 1
  grep -qF "administrator password" <<<"$output"
}

@test "runtime-down off macOS: never claims to be starting a daemon it can't start" {
  OS=Linux
  run _assess_handle_runtime_down
  [ "$status" -eq 0 ] || return 1
  # Starting dockerd needs root. Saying "starting it" here would be the same
  # false promise, one platform over.
  ! grep -qF "starting it" <<<"$output" || return 1
  grep -qF "can't start it for you" <<<"$output" || return 1
  # …and it must say what happens NEXT. "Start it, then re-run" alone reads as
  # "this run is over" while the installer carries straight on into the
  # privileged flow — guidance contradicting the next thing on screen
  # (Bugbot, #741).
  grep -qF "Continuing" <<<"$output" || return 1
  grep -qF "administrator password" <<<"$output"
}

@test "runtime-down on a Mac with NO Docker Desktop: never claims to start it" {
  # Colima-only / headless Macs. Announcing "starting it" and then finding
  # nothing to start reproduces this function's own bug one level down, and the
  # failure copy would tell someone without Docker Desktop to open Docker
  # Desktop (Bugbot, #741).
  OS=Darwin
  _docker_app_installed() { return 1; }            # nothing to launch
  _try_start_docker_desktop() { echo "NUDGED"; return 1; }
  run _assess_handle_runtime_down
  [ "$status" -eq 0 ] || return 1
  ! grep -qF "starting it" <<<"$output" || return 1
  ! grep -qF "NUDGED" <<<"$output" || { echo "nudged with no app installed"; return 1; }
  ! grep -qF "Open Docker Desktop" <<<"$output" || {
    echo "told a machine without Docker Desktop to open Docker Desktop"; return 1
  }
  grep -qF "can't start it for you" <<<"$output"
}

@test "_try_start_docker_desktop: no-ops off macOS and when docker is absent" {
  # `run -1` asserts the ONE refusal code. A bare `-ne 0` also accepts 127
  # (command not found) — and did, while this file wasn't sourcing
  # setup-macos.sh at all, so the test passed having run nothing.
  OS=Linux
  run -1 _try_start_docker_desktop
  OS=Darwin
  has() { return 1; }                              # no docker binary at all
  run -1 _try_start_docker_desktop
}

@test "_try_start_docker_desktop: a live runtime returns 0 without launching anything" {
  OS=Darwin
  has() { return 0; }
  # Stub the PROBE, not `docker`. Since the probe became bounded it runs through
  # timeout(1), i.e. as an external process — which a shell function cannot
  # intercept. Worse, _bounded falls back to running the command bare when
  # neither timeout nor gtimeout is installed, so a `docker()` stub would work
  # on some hosts and not others and this test's meaning would depend on the
  # machine. _docker_answers is the seam that exists on every host.
  _docker_answers() { return 0; }                  # the daemon answers
  open() { echo "LAUNCHED"; }
  run _try_start_docker_desktop
  [ "$status" -eq 0 ] || return 1
  # Nothing to nudge — and the caller must not be able to claim it started it.
  ! grep -qF "LAUNCHED" <<<"$output" || return 1
}

# ── every probe on the nudge path is bounded (Bugbot, #741) ─────────────────
# A bare `docker info` does not return against a WEDGED daemon — and wedged is
# exactly the state that reaches here, because _assess_runtime_down classifies
# runtime-down on _bounded's 124. So the unbounded probe hung on the one input
# that routes to it: "starting it" on screen, then nothing, forever.
#
# These assert the ROUTING (every probe goes through _bounded) rather than
# timing. A wall-clock test would need a real hang to be meaningful, and one
# that sleeps long enough to prove anything is a test nobody runs.

@test "_try_start_docker_desktop: the liveness probe is bounded, never bare" {
  OS=Darwin
  MARK="$BATS_TEST_TMPDIR/probes"; : > "$MARK"
  has() { return 0; }
  _docker_app_installed() { return 0; }
  open() { :; }
  # Record to a FILE, not stdout: _docker_answers redirects its whole call to
  # /dev/null (it is a yes/no probe), so a stub that echoes is invisible — and a
  # test asserting on that invisible output passes or fails for reasons
  # unrelated to what it claims to check.
  docker()   { echo "UNBOUNDED" >> "$MARK"; return 1; }
  _bounded() { echo "BOUNDED:$1" >> "$MARK"; return 1; }
  _wait_for_docker() { return 1; }
  run _try_start_docker_desktop
  grep -q "BOUNDED" "$MARK" || { echo "no bounded probe ran; saw: $(cat "$MARK")"; return 1; }
  ! grep -q "UNBOUNDED" "$MARK" || {
    echo "a bare docker call escaped the bound: $(cat "$MARK")"; return 1
  }
}

@test "_wait_for_docker: probes through _bounded, and the deadline ends it" {
  MARK="$BATS_TEST_TMPDIR/probes"; : > "$MARK"
  docker()   { echo "UNBOUNDED" >> "$MARK"; return 1; }
  _bounded() { echo "BOUNDED" >> "$MARK"; return 1; }
  # polls=0 -> the deadline has already passed, so the loop body never runs and
  # it falls straight to the final verdict without sleeping. That keeps the test
  # instant while still exercising a real probe.
  run _wait_for_docker 0
  [ "$status" -ne 0 ] || return 1
  grep -q "BOUNDED" "$MARK" || { echo "no bounded probe ran; saw: $(cat "$MARK")"; return 1; }
  ! grep -q "UNBOUNDED" "$MARK" || {
    echo "a bare docker call escaped the bound: $(cat "$MARK")"; return 1
  }
}

@test "_docker_answers: routes through _bounded with a positive timeout" {
  MARK="$BATS_TEST_TMPDIR/probes"; : > "$MARK"
  _bounded() { echo "$1" >> "$MARK"; return 0; }
  docker()   { echo "UNBOUNDED" >> "$MARK"; return 1; }
  _docker_answers
  local seen; seen="$(cat "$MARK")"
  # A positive integer, not merely non-empty: "0" would disable the bound while
  # still routing through _bounded — covered-looking and not covered.
  [[ "$seen" =~ ^[1-9][0-9]*$ ]] || { echo "bad timeout: '$seen'"; return 1; }
}

@test "_wait_for_docker's timeout can't kill install_docker_desktop under set -e" {
  # The regression the extraction introduced: _wait_for_docker returns non-zero
  # on timeout and was called as a BARE statement under `set -e`, so the script
  # exited there — before the whale-icon guidance and the deliberate error()
  # that exist precisely for "Docker didn't come up". A silent death replacing
  # a helpful message, in a PR about messages that lie.
  #
  # Asserted on the source rather than by driving install_docker_desktop, which
  # would need brew, hdiutil and a DMG. The call must be guarded — `|| true`,
  # `|| :` or an `if` — never bare.
  local line
  line="$(grep -nE '^[[:space:]]*_wait_for_docker "\$max_wait"' "${LIB_DIR}/setup-macos.sh")" || {
    echo "the install-time call to _wait_for_docker moved; update this guard"; return 1
  }
  grep -qE '\|\||^[[:space:]]*if ' <<<"$line" || {
    echo "unguarded under set -e: $line"; return 1
  }
}

@test "_try_start_docker_desktop: won't launch an app that isn't installed" {
  OS=Darwin
  has() { return 0; }
  # `_bounded() { shift; "$@"; }` is this file's convention for probe tests, and
  # it is load-bearing rather than decorative: without it _bounded runs the
  # command through timeout(1) as an EXTERNAL process, where a `docker()` shell
  # function cannot intercept. This test shipped with only the docker() stub and
  # passed locally — on a laptop with no running daemon — then failed on CI,
  # where the ubuntu runner HAS a live Docker, so the real probe answered and
  # _try_start_docker_desktop returned 0 at "already up" without ever reaching
  # the branch under test.
  _bounded() { shift; "$@"; }
  docker() { return 1; }                           # runtime down
  open() { echo "LAUNCHED"; }
  HOME="$BATS_TEST_TMPDIR/nohome"; mkdir -p "$HOME"
  # Stub the installed-probe rather than depending on the host: on a machine
  # WITH Docker Desktop (every macOS dev box) this branch is otherwise
  # unreachable, and skipping there means only CI ever runs it.
  _docker_app_installed() { return 1; }
  run -1 _try_start_docker_desktop
  ! grep -qF "LAUNCHED" <<<"$output" || return 1
}

@test "_version_lt: a leading 'v' inverts the comparison — callers must strip it" {
  # Documents the trap rather than the intent: "v1.36.3" parses its first
  # component as non-numeric, which reads as 0, so it compares BELOW 1.31.0.
  # Any version gate that forgets `${VAR#v}` therefore fails silently in the
  # permissive direction. cluster.sh's fail-cgroupv1 gate depends on this.
  _version_lt "v1.36.3" "1.31.0" || return 1     # the trap: TRUE, though 1.36 > 1.31
  ! _version_lt "1.36.3" "1.31.0" || return 1    # stripped: correct
}
