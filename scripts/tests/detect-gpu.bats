#!/usr/bin/env bats
# Tests for scripts/lib/detect-gpu.sh — GPU vendor / driver-state detection.
#
# The load-bearing property: install-k8s.sh sources this lib under
# `set -euo pipefail`, and GPU_VENDOR decides whether the cluster is created
# with GPU access at all. The lspci probes used to be `lspci | grep -qi …`:
# grep -q exits on its FIRST hit, lspci takes SIGPIPE, and pipefail turns the
# pipeline into 141 — which the `if` reads as "no such GPU". A GPU host then
# silently got a CPU-mode cluster (backend#1778, client#686).
#
# The match must LEAD in these fixtures. With the GPU line appended AFTER the
# filler, grep -q has to read the whole stream and never closes early, so the
# test would pass against the UNFIXED code — the vacuous-test trap from #680.
#
# macOS-bats blindspot (see assess.bats): bash 3.2 can silently pass a failing
# bare `[[ … ]]` used as a test's last statement, so every assertion here ends
# in an explicit `|| return 1` and status checks use single brackets.
load test_helper

setup() {
  load_lib detect-gpu.sh
  OS=Linux; ARCH=x86_64
  GPU_VENDOR="none"; NVIDIA_DRIVER_OK=false
}

# An lspci listing with the interesting device FIRST and ~1.4MB of other
# devices after it — well past the 64KB pipe buffer, and lspci streams
# device-per-line, so grep -q closing early is guaranteed to SIGPIPE it.
_big_lspci() {
  local first="$1" i=0
  printf '%s\n' "$first"
  while [ "$i" -lt 20000 ]; do
    printf '00:%02x.0 Ethernet controller: Intel Corporation I350 Gigabit Network Connection (rev 01)\n' "$i"
    i=$((i + 1))
  done
}

# detect_gpu sets globals and logs; report the globals on stdout so `run`
# (which executes in a subshell) can assert on them.
_vendor() { detect_gpu >/dev/null 2>&1; printf '%s %s\n' "$GPU_VENDOR" "$NVIDIA_DRIVER_OK"; }

@test "NVIDIA on a device-dense host is still detected under pipefail (backend#1778)" {
  has() { [ "$1" = lspci ]; }
  lspci() { _big_lspci "01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090]"; }
  set -o pipefail
  run _vendor
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "nvidia false" ] || return 1
}

@test "AMD on a device-dense host is still detected under pipefail (backend#1778)" {
  has() { [ "$1" = lspci ]; }
  lspci() { _big_lspci "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Radeon RX 7900 XTX"; }
  set -o pipefail
  run _vendor
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == "amd "* ]] || return 1
}

@test "the AMD label names the card and is not blanked by the filler" {
  has() { [ "$1" = lspci ]; }
  lspci() { _big_lspci "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Radeon RX 7900 XTX"; }
  set -o pipefail
  run detect_gpu
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Radeon RX 7900 XTX"* ]] || return 1
  # Exactly the first matching line — not the whole capture glued together.
  [[ "$output" != *"I350 Gigabit"* ]] || return 1
}

@test "a device-dense host with NO GPU still reports none (the fix did not invert the verdict)" {
  has() { [ "$1" = lspci ]; }
  lspci() { _big_lspci "00:1f.2 SATA controller: Intel Corporation C610/X99 series chipset sSATA Controller"; }
  set -o pipefail
  run _vendor
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "none false" ] || return 1
}

@test "nvidia-smi present short-circuits before lspci is consulted" {
  has() { [ "$1" = nvidia-smi ]; }
  nvidia-smi() { printf 'NVIDIA A100-SXM4-80GB\n'; }
  lspci() { echo "SHOULD_NOT_RUN"; return 1; }
  set -o pipefail
  run _vendor
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "nvidia true" ] || return 1
}

@test "no lspci and no nvidia-smi is not an error under set -euo pipefail" {
  # detect_gpu runs bare (not in an `if`) in install-k8s.sh, so a non-zero
  # return would abort the installer outright.
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/detect-gpu.sh"
    LOG_FILE=/dev/null; OS=Linux; ARCH=x86_64
    GPU_VENDOR=none; NVIDIA_DRIVER_OK=false
    has() { return 1; }
    detect_gpu >/dev/null 2>&1
    echo "REACHED_END vendor=$GPU_VENDOR"
  '
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"REACHED_END vendor=none"* ]] || return 1
}
