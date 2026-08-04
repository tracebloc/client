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
# `has() { return 1; }` so _bounded takes its passthrough branch and runs the
# nvidia-ctk/nvidia-smi FUNCTION mocks. Without it, on a runner that HAS timeout(1)
# (CI) _bounded would exec the real (absent) binaries via `timeout`, which can't see
# shell-function mocks — the mocks only survive when timeout/gtimeout are reported absent.
@test "_gpu_stack_signature: combines toolkit + driver versions" {
  has() { return 1; }
  nvidia-ctk() { echo "NVIDIA Container Toolkit CLI version 1.15.0"; }
  nvidia-smi() { echo "550.54.14"; }
  run _gpu_stack_signature
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"1.15.0"* && "$output" == *"550.54.14"* ]] || return 1
}
@test "_gpu_stack_signature: empty when neither tool reports a version" {
  has() { return 1; }
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

# ── #431 Bugbot round: bounded probes, surfaced restart failure, forced re-verify ──
@test "both probes are bounded (no unbounded docker/k3d call at the skip gate) (#431 Bugbot)" {
  f="$BATS_TEST_DIRNAME/../lib/gpu-nvidia.sh"
  # _docker_default_runtime_is_nvidia + _k3d_cluster_running must go through _bounded.
  run bash -c "awk '/^_docker_default_runtime_is_nvidia\(\)/{d=1} d&&/_bounded .* docker info/{print \"docker-ok\"; d=0}' '$f'"
  [ "$output" = "docker-ok" ] || return 1
  grep -q '_bounded .* k3d cluster list' "$f" || return 1
  # the post-restart `k3d cluster start` must carry its own deadline (k3d waits
  # forever by default) — #431 Bugbot r2.
  grep -qE 'k3d cluster start "\$CLUSTER_NAME" --wait --timeout' "$f" || return 1
  # the signature probes (nvidia-ctk/nvidia-smi) run at the skip gate too — bounded — #431 Bugbot r5.
  grep -q '_bounded .* nvidia-ctk --version' "$f" || return 1
  grep -q '_bounded .* nvidia-smi --query' "$f" || return 1
}

@test "install_nvidia_container_toolkit: a failed cluster restart is surfaced, not swallowed (#431 Bugbot)" {
  _gpu_mocks
  K3D_PRESENT=0
  k3d() {
    record "k3d $*"
    case "$*" in
      *"cluster list"*)  printf '%s\n' "tracebloc 1/1 0/0 true" ;;
      *"cluster start"*) echo "k3d: docker daemon not responding" >&2; return 1 ;;
    esac
  }
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; esac; }
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Couldn't restart"* ]] || return 1
  [[ "$output" == *"Start it manually"* ]] || return 1
}

@test "install_nvidia_container_toolkit: a reconfigure re-verifies even with a matching marker (#431 Bugbot)" {
  _gpu_mocks
  K3D_PRESENT=1                                                # no live cluster (has k3d -> false)
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; esac; }   # NOT nvidia -> reconfigure
  printf 'toolkit 1.15.0|550.00' > "${HOST_DATA_DIR}/.gpu-smoke-ok"          # marker matches the signature
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'docker run' "$MOCK_CALLS" || return 1              # cache bypassed: smoke test STILL ran
}

# ── #431 Bugbot round 3: tri-state cluster probe + stale marker on failed smoke ──
@test "_k3d_cluster_running: a failed/timed-out probe is UNKNOWN (rc 2), not 'not running' (#431 Bugbot)" {
  has() { case "$1" in k3d) return 0;; *) return 1;; esac; }
  k3d() { return 1; }                    # `cluster list` fails (wedged daemon)
  run _k3d_cluster_running
  [ "$status" -eq 2 ] || return 1
}

@test "install_nvidia_container_toolkit: unknown cluster state still attempts recovery + warns (#431 Bugbot)" {
  _gpu_mocks
  K3D_PRESENT=0                          # has k3d -> true
  k3d() { record "k3d $*"; case "$*" in *"cluster list"*) return 1;; *"cluster start"*) return 0;; esac; }
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; esac; }   # not-nvidia -> reconfigure
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Couldn't confirm"* ]] || return 1        # unknown-state warn
  grep -q 'k3d cluster start' "$MOCK_CALLS" || return 1       # recovery attempted anyway
}

@test "install_nvidia_container_toolkit: a failed forced smoke test clears the stale pass marker (#431 Bugbot)" {
  _gpu_mocks
  K3D_PRESENT=1                          # no live cluster
  docker() { record "docker $*"; case "$*" in *info*) echo runc;; *"run"*) return 1;; esac; }  # reconfigure + smoke FAILS
  printf 'toolkit 1.15.0|550.00' > "${HOST_DATA_DIR}/.gpu-smoke-ok"
  run install_nvidia_container_toolkit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'docker run' "$MOCK_CALLS" || return 1               # forced re-verify ran
  [ ! -f "${HOST_DATA_DIR}/.gpu-smoke-ok" ] || return 1         # stale PASS marker removed
}

# ── #431 Bugbot round 4: set -e safety (the installer sources these under set -euo) ──
@test "_gpu_stack_signature is set -e safe with no versions (#431 Bugbot)" {
  run bash -c '
    set -euo pipefail
    source "$1/../lib/common.sh"
    source "$1/../lib/gpu-nvidia.sh"
    nvidia-ctk() { return 1; }
    nvidia-smi() { return 1; }
    sig="$(_gpu_stack_signature)"
    echo "DONE:[${sig}]"
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"DONE:[]"* ]] || return 1
}

@test "_k3d_cluster_running is set -e safe on a failed probe -> UNKNOWN (#431 Bugbot)" {
  run bash -c '
    set -euo pipefail
    source "$1/../lib/common.sh"
    source "$1/../lib/gpu-nvidia.sh"
    CLUSTER_NAME=tracebloc
    has() { case "$1" in k3d) return 0;; *) return 1;; esac; }
    k3d() { return 1; }
    cr=0; _k3d_cluster_running || cr=$?
    echo "DONE:cr=${cr}"
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"DONE:cr=2"* ]] || return 1
}

# ── bounded GPU apply (Bugbot) ───────────────────────────────────────────────
@test "the GPU manifest apply is bounded: --request-timeout, so a wedged API can't hang it (Bugbot)" {
  # _apply_remote_manifest redirects apply output to the log; without a request
  # timeout a wedged API server would hang silently instead of failing into the
  # caller's recoverable CPU-mode warn.
  grep -Eq 'kubectl apply -f "\$tmp_yml" --request-timeout=' \
    "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
}

@test "GPU success is gated on the rollout exit code — no false 'enabled' after a failed rollout (Bugbot)" {
  # A timed-out/failed rollout means the plugin isn't confirmed ready. Gating now
  # lives in the shared _gpu_rollout_gate (the nvidia path delegates to it); the gate
  # puts success in the rollout then-branch with a CPU-mode warn on failure.
  grep -q '_gpu_rollout_gate nvidia-device-plugin-daemonset' \
    "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
  grep -q 'rollout status "daemonset/' \
    "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
  grep -q "Couldn't confirm GPU acceleration is ready" \
    "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
}

@test "GPU verify is gated on a successful deploy so CPU-mode skips the ~90s wait (Bugbot)" {
  grep -Eq 'if deploy_gpu_device_plugin; then' "$BATS_TEST_DIRNAME/../install-k8s.sh"
}

@test "_deploy_nvidia_plugin returns non-zero on a CPU-mode (apply-failure) path (Bugbot)" {
  # A failed deploy must signal non-zero so the caller skips verify_gpu.
  run bash -c '
    set -euo pipefail
    GPU_VENDOR=nvidia; NVIDIA_DEVICE_PLUGIN_URL=http://example/x.yml; LOG_FILE=/dev/null
    log(){ :; }; success(){ :; }; warn(){ :; }
    source "'"$BATS_TEST_DIRNAME"'/../lib/gpu-plugins.sh"
    _apply_remote_manifest(){ return 1; }   # override AFTER source: simulate apply failure
    kubectl(){ return 1; }                    # get daemonset -> not present
    _deploy_nvidia_plugin && echo RC0 || echo "RC$?"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"RC1"* ]] || { echo "expected non-zero return; got: $output"; return 1; }
}

@test "_gpu_rollout_gate: rollout failure -> warn CPU-mode + non-zero, no success (reviewer)" {
  run bash -c '
    set -euo pipefail
    LOG_FILE=/dev/null
    log(){ :; }; success(){ echo "SUCCESS:$*"; }; warn(){ echo "WARN:$*"; }
    source "'"$BATS_TEST_DIRNAME"'/../lib/gpu-plugins.sh"
    kubectl(){ return 1; }   # rollout status fails
    _gpu_rollout_gate amdgpu-device-plugin && echo RC0 || echo "RC$?"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"WARN:"* ]] || return 1
  [[ "$output" == *"RC1"* ]] || return 1
  [[ "$output" != *"SUCCESS:"* ]] || return 1
}

@test "_gpu_rollout_gate: rollout success -> success + return 0" {
  run bash -c '
    set -euo pipefail
    LOG_FILE=/dev/null
    log(){ :; }; success(){ echo "SUCCESS:$*"; }; warn(){ echo "WARN:$*"; }
    source "'"$BATS_TEST_DIRNAME"'/../lib/gpu-plugins.sh"
    kubectl(){ return 0; }   # rollout status ok
    _gpu_rollout_gate nvidia-device-plugin-daemonset && echo RC0 || echo "RC$?"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"SUCCESS:"* ]] || return 1
  [[ "$output" == *"RC0"* ]] || return 1
}

@test "GPU existence probes are bounded with --request-timeout (reviewer parity)" {
  # Both the nvidia and amd 'already installed?' checks must carry a request timeout
  # so a wedged API can't hang before the bounded apply is ever reached.
  run grep -cE 'kubectl get daemonset .*--request-timeout=' "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
  [ "$output" -ge 2 ] || return 1
}

@test "amd primary AND master fallback both gate on rollout (reviewer)" {
  # A master apply that never rolls out must warn CPU-mode via the shared gate, not
  # return a false success that makes the caller's verify poll ~90s.
  run grep -c '_gpu_rollout_gate amdgpu-device-plugin' "$BATS_TEST_DIRNAME/../lib/gpu-plugins.sh"
  [ "$output" -eq 2 ] || return 1
}
