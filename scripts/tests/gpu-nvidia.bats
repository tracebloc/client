#!/usr/bin/env bats
# Tests for scripts/lib/gpu-nvidia.sh — idempotent GPU reconfigure (#431).
#
# The load-bearing property: a re-run on an ALREADY-configured GPU host must not
# restart Docker (which takes a live k3d cluster down) and must not re-pull the CUDA
# smoke-test image. A genuinely changed config still applies.
#
# macOS-bats blindspot (see gpu-amd.bats/assess.bats): bash 3.2 can silently pass a
# failing bare `[[ … ]]` used as a test's last statement, so assertions end in an
# explicit `return 1` and status checks use single brackets.
load test_helper

setup() {
  load_lib gpu-nvidia.sh
  MOCK_CALLS="$(mktemp)"
  CLUSTER_NAME=tracebloc
  HOST_DATA_DIR="$(mktemp -d)"
}

# ── _docker_default_runtime_is_nvidia ──────────────────────────────────────
@test "_docker_default_runtime_is_nvidia: true when docker info reports nvidia" {
  has() { [ "$1" = docker ]; }
  docker() { case "$*" in *info*) echo nvidia;; esac; }
  run _docker_default_runtime_is_nvidia
  [ "$status" -eq 0 ] || return 1
}
@test "_docker_default_runtime_is_nvidia: false for a non-nvidia default" {
  has() { [ "$1" = docker ]; }
  docker() { case "$*" in *info*) echo runc;; esac; }
  run _docker_default_runtime_is_nvidia
  [ "$status" -ne 0 ] || return 1
}
@test "_docker_default_runtime_is_nvidia: false when docker is absent" {
  has() { return 1; }
  run _docker_default_runtime_is_nvidia
  [ "$status" -ne 0 ] || return 1
}

# ── _k3d_cluster_running ───────────────────────────────────────────────────
@test "_k3d_cluster_running: true when the named cluster has a server up (1/1)" {
  has() { [ "$1" = k3d ]; }
  k3d() { printf '%s\n' "tracebloc   1/1   0/0   true"; }
  run _k3d_cluster_running
  [ "$status" -eq 0 ] || return 1
}
@test "_k3d_cluster_running: false when the cluster is stopped (0/1)" {
  has() { [ "$1" = k3d ]; }
  k3d() { printf '%s\n' "tracebloc   0/1   0/0   false"; }
  run _k3d_cluster_running
  [ "$status" -ne 0 ] || return 1
}
@test "_k3d_cluster_running: false when the named cluster is absent" {
  has() { [ "$1" = k3d ]; }
  k3d() { printf '%s\n' "other   1/1   0/0   true"; }
  run _k3d_cluster_running
  [ "$status" -ne 0 ] || return 1
}

# ── _gpu_stack_signature ───────────────────────────────────────────────────
@test "_gpu_stack_signature: combines toolkit + driver versions" {
  nvidia-ctk() { echo "NVIDIA Container Toolkit CLI version 1.15.0"; }
  nvidia-smi() { echo "550.54.14"; }
  run _gpu_stack_signature
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"1.15.0"* && "$output" == *"550.54.14"* ]] || return 1
}
@test "_gpu_stack_signature: empty when neither tool reports a version" {
  nvidia-ctk() { return 1; }
  nvidia-smi() { return 1; }
  run _gpu_stack_signature
  [ -z "$output" ] || return 1
}

# ── install_nvidia_container_toolkit: idempotent reconfigure (the acceptance) ──
# Shared mocks: toolkit already present, containerd reconfigure is a no-op, smoke
# test "passes". `sudo X` runs the mocked X so we capture the real intent.
_gpu_mocks() {
  has() { case "$1" in nvidia-ctk|docker) return 0;; k3d) return "${K3D_PRESENT:-1}";; *) return 1;; esac; }
  nvidia-ctk() { record "nvidia-ctk $*"; echo "toolkit 1.15.0"; }
  nvidia-smi() { echo "550.00"; }
  systemctl() { record "systemctl $*"; }
  sudo() { record "sudo $*"; "$@" >/dev/null 2>&1 || true; }
}

@test "install_nvidia_container_toolkit: docker already nvidia -> NO reconfigure, NO restart (#431)" {
  _gpu_mocks
  docker() { record "docker $*"; case "$*" in *info*) echo nvidia;; esac; }
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q 'systemctl restart docker' "$MOCK_CALLS" || return 1
  ! grep -q 'runtime configure --runtime=docker' "$MOCK_CALLS" || return 1
}

@test "install_nvidia_container_toolkit: docker NOT nvidia -> reconfigure + restart applied (#431)" {
  _gpu_mocks
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; esac; }
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'runtime configure --runtime=docker' "$MOCK_CALLS" || return 1
  grep -q 'systemctl restart docker' "$MOCK_CALLS" || return 1
}

@test "install_nvidia_container_toolkit: NOT-nvidia with a live cluster warns + restarts it (#431)" {
  _gpu_mocks
  K3D_PRESENT=0                                   # has k3d -> true
  k3d() { record "k3d $*"; case "$*" in *"cluster list"*) printf '%s\n' "tracebloc 1/1 0/0 true";; esac; }
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; esac; }
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"cluster will restart"* ]] || return 1
  grep -q 'k3d cluster start tracebloc' "$MOCK_CALLS" || return 1
}

@test "install_nvidia_container_toolkit: cached smoke test skips the CUDA image pull (#431)" {
  _gpu_mocks
  docker() { record "docker $*"; case "$*" in *info*) echo nvidia;; esac; }
  # Pre-seed the marker with the exact signature the run will compute.
  printf 'toolkit 1.15.0|550.00' > "${HOST_DATA_DIR}/.gpu-smoke-ok"
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q 'docker run' "$MOCK_CALLS" || return 1     # no CUDA image pull
}

@test "install_nvidia_container_toolkit: first run records the smoke-test signature (#431)" {
  _gpu_mocks
  docker() { record "docker $*"; case "$*" in *info*) echo nvidia;; esac; }   # smoke "passes" (default rc 0)
  [ ! -f "${HOST_DATA_DIR}/.gpu-smoke-ok" ] || return 1
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'docker run' "$MOCK_CALLS" || return 1                              # ran the smoke test
  [ -f "${HOST_DATA_DIR}/.gpu-smoke-ok" ] || return 1                          # cached its result
}
