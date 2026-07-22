#!/usr/bin/env bats
# Tests for scripts/lib/common.sh — config validation, the install_cleanup
# CLIENT_STATE guard (#716), retry, has.
load test_helper

setup() {
  load_lib
}

# ── validate_config ────────────────────────────────────────────────────────
@test "validate_config: valid config passes" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1
  HOST_DATA_DIR="$HOME/.tracebloc"
  run validate_config
  [ "$status" -eq 0 ]
}

@test "validate_config: invalid CLUSTER_NAME -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME="1nope"; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/x"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLUSTER_NAME"* ]]
}

@test "validate_config: invalid SERVERS -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=ok; SERVERS=0; AGENTS=1; HOST_DATA_DIR="$HOME/x"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"SERVERS"* ]]
}

@test "validate_config: HOST_DATA_DIR outside HOME -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="/tmp/not-under-home-$$"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"HOST_DATA_DIR"* ]]
}

# ── validate_config: HOST_DATASET_DIR (backend#743) ──────────────────────────
# Resolve HOME to its physical path so the HOST_DATA_DIR under-$HOME check (which
# uses cd -P) is not tripped by macOS's /var -> /private/var symlink (Linux/CI
# has none). The dataset dir itself MAY live outside $HOME — that's the point.
@test "validate_config: HOST_DATASET_DIR outside HOME but existing+writable -> passes" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/dataset-mount"; mkdir -p "$HOST_DATASET_DIR"
  run validate_config
  [ "$status" -eq 0 ]
}

@test "validate_config: HOST_DATASET_DIR does not exist -> error (never mkdir a share root)" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/nope-$$"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate_config: HOST_DATASET_DIR not writable -> error" {
  [[ "$(id -u)" -eq 0 ]] && skip "root bypasses filesystem permission bits"
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/ro-mount"; mkdir -p "$HOST_DATASET_DIR"; chmod 555 "$HOST_DATASET_DIR"
  run validate_config
  chmod 755 "$HOST_DATASET_DIR"   # restore so bats can clean up the tmpdir
  [ "$status" -ne 0 ]
  [[ "$output" == *"not writable"* ]]
}

@test "validate_config: HOST_DATA_DIR still rejected outside HOME when dataset dir is set" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="/tmp/not-under-home-$$"
  HOST_DATASET_DIR="$HOME/dataset-mount"; mkdir -p "$HOST_DATASET_DIR"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"HOST_DATA_DIR"* ]]
}

# ── install_cleanup: the CLIENT_STATE guard (#716) ─────────────────────────
@test "install_cleanup: exit 0 -> silent" {
  out="$( ( exit 0 ); install_cleanup 2>&1 )"
  [[ "$out" != *"did not complete"* ]]
}

@test "install_cleanup: failure + CLIENT_STATE set -> suppresses generic message" {
  CLIENT_STATE=connected
  out="$( ( exit 1 ); install_cleanup 2>&1 )"
  [[ "$out" != *"did not complete"* ]]
}

@test "install_cleanup: failure + CLIENT_STATE unset -> shows generic message" {
  unset CLIENT_STATE
  out="$( ( exit 1 ); install_cleanup 2>&1 )"
  [[ "$out" == *"did not complete"* ]]
}

@test "install_cleanup: exit 2 -> re-run hint" {
  unset CLIENT_STATE
  out="$( ( exit 2 ); install_cleanup 2>&1 )"
  [[ "$out" == *"Re-run required"* || "$out" == *"Complete the step"* ]]
}

# ── retry ──────────────────────────────────────────────────────────────────
@test "retry: succeeds on first attempt" {
  run retry 3 1 true
  [ "$status" -eq 0 ]
}

@test "retry: gives up after max attempts" {
  run retry 2 0 false
  [ "$status" -ne 0 ]
}

@test "retry: succeeds after a transient failure" {
  marker="$BATS_TEST_TMPDIR/m"
  flaky() { if [ -f "$marker" ]; then return 0; fi; touch "$marker"; return 1; }
  run retry 3 0 flaky
  [ "$status" -eq 0 ]
}

# ── has ────────────────────────────────────────────────────────────────────
@test "has: present command" { run has bash; [ "$status" -eq 0 ]; }
@test "has: absent command" { run has nope-not-a-real-cmd-xyz; [ "$status" -ne 0 ]; }

# ── check_docker_arch_mac (no-op off macOS) ────────────────────────────────
@test "check_docker_arch_mac: no-op on non-macOS" {
  run check_docker_arch_mac
  [ "$status" -eq 0 ]
}

# ── count_bar (first-run: honest N-of-M for multi-image pulls) ───────────────
@test "count_bar: renders 'N of M <noun>'" {
  run count_bar 3 6 services
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 of 6 services"* ]]
}

@test "count_bar: clamps current above total (never over-reports)" {
  run count_bar 9 6 services
  [[ "$output" == *"6 of 6 services"* ]]
  [[ "$output" != *"9 of 6"* ]]
}

@test "count_bar: non-numeric current -> 0 (no crash)" {
  run count_bar nope 6 services
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 of 6 services"* ]]
}

@test "count_bar: total<1 floored to 1 (no divide-by-zero)" {
  run count_bar 0 0 services
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 of 1 services"* ]]
}

# ── step_header (first-run: bold a–f running headers) ────────────────────────
@test "step_header: renders '<letter>) <Title>'" {
  run step_header a "Checking your machine"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a) Checking your machine"* ]]
}

# ── print_roadmap (the '2. Installing' a–f plan) ─────────────────────────────
@test "print_roadmap: lists the a–f plan under '2. Installing'" {
  run print_roadmap
  [ "$status" -eq 0 ]
  [[ "$output" == *"2. Installing"* ]]
  [[ "$output" == *"a) Check your machine"* ]]
  [[ "$output" == *"b) Install what tracebloc needs"* ]]
  [[ "$output" == *"c) Create your secure environment"* ]]
  [[ "$output" == *"d) Register this machine"* ]]
  [[ "$output" == *"e) Install tracebloc"* ]]
  [[ "$output" == *"f) Connect to the tracebloc network"* ]]
}

# ── print_banner (title + version; suppressed after the bootstrap drew it) ───
@test "print_banner: title + version when TB_VERSION is set" {
  unset TRACEBLOC_BANNER_SHOWN
  TB_VERSION="v1.9.3"; OS=Darwin; ARCH=arm64
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$BATS_TEST_TMPDIR/.tracebloc"
  run print_banner
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setting up"* ]]
  [[ "$output" == *"tracebloc"* ]]
  [[ "$output" == *"v1.9.3"* ]]
}

@test "print_banner: suppressed when the bootstrap already drew it (TRACEBLOC_BANNER_SHOWN)" {
  export TRACEBLOC_BANNER_SHOWN=1
  OS=Darwin; ARCH=arm64; CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/.tracebloc"
  run print_banner
  [ "$status" -eq 0 ]
  [[ "$output" != *"Setting up"* ]]
  unset TRACEBLOC_BANNER_SHOWN
}

# ── Root-aware sudo + preflight (RFC 0001 A2) ────────────────────────────────
# _have_sudo_bin / _real_sudo are stubbed so every branch runs without a real
# sudo; the payload command is a recordable mock so the root path never shells
# out to a real binary.
@test "sudo(): as root, runs the command directly — no real sudo" {
  MOCK_CALLS="$(mktemp)"
  id() { echo 0; }
  modprobe() { record "modprobe $*"; }
  _real_sudo() { record "real_sudo $*"; }
  run sudo modprobe overlay
  [ "$status" -eq 0 ]
  mock_calls | grep -q "modprobe overlay"
  ! mock_calls | grep -q "real_sudo"
}

@test "sudo(): non-root with sudo present defers to the real sudo" {
  MOCK_CALLS="$(mktemp)"
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "real_sudo $*"; }
  run sudo modprobe overlay
  [ "$status" -eq 0 ]
  mock_calls | grep -q "real_sudo modprobe overlay"
}

@test "sudo(): non-root without sudo returns 127 (best-effort friendly), never exits" {
  id() { echo 1000; }
  _have_sudo_bin() { return 1; }
  run sudo modprobe overlay
  [ "$status" -eq 127 ]
}

@test "preflight_sudo: root returns 0 with no sudo binary needed" {
  id() { echo 0; }
  _have_sudo_bin() { return 1; }   # even with NO sudo, root is fine
  _real_sudo() { echo "must-not-run"; return 1; }
  run preflight_sudo
  [ "$status" -eq 0 ]
}

@test "preflight_sudo: non-root + no sudo => accurate error, not 'no sudo access'" {
  id() { echo 1000; }
  _have_sudo_bin() { return 1; }
  run preflight_sudo
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF "isn't installed"
}

@test "preflight_sudo: non-root + passwordless sudo returns 0 (no prompt)" {
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { case "$*" in "-n true") return 0 ;; *) return 1 ;; esac; }
  run preflight_sudo
  [ "$status" -eq 0 ]
}
