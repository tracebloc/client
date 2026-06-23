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
