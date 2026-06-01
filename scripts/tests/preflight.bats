#!/usr/bin/env bats
# Tests for scripts/lib/preflight.sh — fail-fast environment checks
# (arch / connectivity / disk / RAM / CPU). The checks delegate to small
# injectable readers, which we override here so nothing touches the real
# network, df, or /proc. Counter assertions call the function directly (bats
# `run` executes in a subshell, so PF_HARD_FAIL wouldn't propagate back).
load test_helper

setup() {
  load_lib preflight.sh
  PF_HARD_FAIL=0
  # Default-safe stubs (a healthy amd64 box); individual tests override.
  _pf_probe_url() { echo ok; }
  _pf_free_kb() { echo $((50 * 1024 * 1024)); }       # 50 GB
  _pf_total_mem_kb() { echo $((8 * 1024 * 1024)); }   # 8 GB
  _pf_ncpu() { echo 4; }
  _pf_amd64_emulation_available() { return 0; }
  docker() { return 1; }   # keep _pf_docker_root off the real daemon
  has() { return 0; }      # pretend tools present (conds empty) unless overridden
  OS="Linux"; ARCH="x86_64"
}

# ── _pf_arch ─────────────────────────────────────────────────────────────────
@test "_pf_arch: amd64 -> success, no hard fail" {
  ARCH=x86_64
  run _pf_arch
  [ "$status" -eq 0 ]
  [[ "$output" == *"amd64"* ]]
}

@test "_pf_arch: arm64 Linux without emulation -> hard fail + binfmt remedy" {
  ARCH=aarch64; OS=Linux
  _pf_amd64_emulation_available() { return 1; }
  run _pf_arch
  [[ "$output" == *"amd64-only"* ]]
  [[ "$output" == *"tonistiigi/binfmt"* ]]
  PF_HARD_FAIL=0; _pf_arch >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_arch: arm64 Linux WITH emulation -> info, no hard fail" {
  ARCH=aarch64; OS=Linux
  _pf_amd64_emulation_available() { return 0; }
  PF_HARD_FAIL=0; _pf_arch >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_arch: arm64 macOS -> info (Desktop emulation), no hard fail" {
  ARCH=arm64; OS=Darwin
  PF_HARD_FAIL=0; _pf_arch >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_arch: arm64 + TRACEBLOC_ALLOW_ARM64 -> warn, no hard fail" {
  ARCH=aarch64; OS=Linux; export TRACEBLOC_ALLOW_ARM64=1
  _pf_amd64_emulation_available() { return 1; }
  run _pf_arch
  [[ "$output" == *"proceeding"* ]]
  PF_HARD_FAIL=0; _pf_arch >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
  unset TRACEBLOC_ALLOW_ARM64
}

# ── _pf_connectivity ─────────────────────────────────────────────────────────
@test "_pf_connectivity: all reachable -> no hard fail" {
  _pf_probe_url() { echo ok; }
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_connectivity: a critical host blocked -> hard fail + allowlist hint" {
  _pf_probe_url() { case "$1" in *ghcr*) echo blocked ;; *) echo ok ;; esac; }
  run _pf_connectivity
  [[ "$output" == *"ghcr.io) unreachable"* ]]
  [[ "$output" == *"Allow HTTPS"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_connectivity: TLS error -> break-and-inspect (Gap D) hint" {
  _pf_probe_url() { case "$1" in *registry-1.docker*) echo tls ;; *) echo ok ;; esac; }
  run _pf_connectivity
  [[ "$output" == *"break-and-inspect"* ]]
}

@test "_pf_connectivity: tool host skipped when the tool is present" {
  _pf_probe_url() { echo ok; }
  has() { return 0; }
  run _pf_connectivity
  [[ "$output" != *"get.docker.com"* ]]
}

@test "_pf_connectivity: tool host probed (warn-only) when the tool is missing" {
  _pf_probe_url() { case "$1" in *get.docker.com*) echo blocked ;; *) echo ok ;; esac; }
  has() { return 1; }
  OS=Linux
  run _pf_connectivity
  [[ "$output" == *"get.docker.com"* ]]
  # a missing tool host is warn-only, never a hard fail
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

# ── _pf_disk / _pf_memory / _pf_cpu ──────────────────────────────────────────
@test "_pf_disk: ample free space -> success" {
  OS=Linux; _pf_free_kb() { echo $((50 * 1024 * 1024)); }
  run _pf_disk; [[ "$output" == *"50 GB free"* ]]
  PF_HARD_FAIL=0; _pf_disk >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_disk: low (<20 GB) -> warn, no hard fail" {
  OS=Linux; _pf_free_kb() { echo $((10 * 1024 * 1024)); }
  run _pf_disk; [[ "$output" == *"recommended"* ]]
  PF_HARD_FAIL=0; _pf_disk >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_disk: critically low (<5 GB) -> hard fail" {
  OS=Linux; _pf_free_kb() { echo $((2 * 1024 * 1024)); }
  run _pf_disk; [[ "$output" == *"need"* ]]
  PF_HARD_FAIL=0; _pf_disk >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_disk: macOS -> info only (Desktop VM disk is opaque)" {
  OS=Darwin; _pf_free_kb() { echo $((2 * 1024 * 1024)); }   # even 'low' must not fail
  PF_HARD_FAIL=0; _pf_disk >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: low RAM -> warn" {
  _pf_total_mem_kb() { echo $((2 * 1024 * 1024)); }
  run _pf_memory; [[ "$output" == *"recommended"* ]]
}

@test "_pf_memory: ample RAM -> success" {
  _pf_total_mem_kb() { echo $((8 * 1024 * 1024)); }
  run _pf_memory; [[ "$output" == *"8 GB"* ]]
}

@test "_pf_cpu: too few cores -> warn" {
  _pf_ncpu() { echo 1; }
  run _pf_cpu; [[ "$output" == *"recommended"* ]]
}

@test "_pf_cpu: enough cores -> success" {
  _pf_ncpu() { echo 4; }
  run _pf_cpu; [[ "$output" == *"4 cores"* ]]
}

# ── run_preflight orchestration ──────────────────────────────────────────────
@test "run_preflight: TRACEBLOC_SKIP_PREFLIGHT -> skipped, exit 0" {
  export TRACEBLOC_SKIP_PREFLIGHT=1
  run run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  unset TRACEBLOC_SKIP_PREFLIGHT
}

@test "run_preflight: a hard failure -> non-zero exit + aggregated summary" {
  ARCH=x86_64; OS=Linux
  _pf_probe_url() { case "$1" in *registry-1.docker*) echo blocked ;; *) echo ok ;; esac; }
  run run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"Preflight failed"* ]]
}

@test "run_preflight: healthy environment -> exit 0" {
  ARCH=x86_64; OS=Linux
  _pf_probe_url() { echo ok; }
  run run_preflight
  [ "$status" -eq 0 ]
}

# ── real _pf_probe_url + readers (setup() stubs them; re-source for the real ones) ──
@test "_pf_probe_url: maps curl outcomes to tokens" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"   # restore the real function
  has() { return 0; }                                  # 'has curl' true
  curl() { return 6; };             run _pf_probe_url https://x; [ "$output" = "dns" ]
  curl() { return 7; };             run _pf_probe_url https://x; [ "$output" = "refused" ]
  curl() { return 28; };            run _pf_probe_url https://x; [ "$output" = "timeout" ]
  curl() { return 60; };            run _pf_probe_url https://x; [ "$output" = "tls" ]
  curl() { printf '200'; return 0;};run _pf_probe_url https://x; [ "$output" = "ok" ]
}

@test "_pf_probe_url: missing curl -> nocurl" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  has() { return 1; }
  run _pf_probe_url https://x
  [ "$output" = "nocurl" ]
}

@test "_pf readers return a number on this host" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  OS="$(uname -s)"
  run _pf_ncpu;         [[ "$output" =~ ^[0-9]+$ ]]
  run _pf_total_mem_kb; [[ "$output" =~ ^[0-9]+$ ]]
  run _pf_free_kb /;    [[ "$output" =~ ^[0-9]+$ ]]
}
