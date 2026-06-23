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
  _pf_fstype() { echo ext4; }                          # local disk (storage check passes)
  _pf_total_mem_kb() { echo $((8 * 1024 * 1024)); }   # 8 GB
  _pf_ncpu() { echo 4; }
  _pf_runtime_mem_kb() { echo ""; }   # daemon "down" in tests → selectors/src use host
  _pf_runtime_ncpu() { echo ""; }
  _pf_avail_mem_kb() { echo $((50 * 1024 * 1024)); }   # 50 GB available (Linux warn off)
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
  has() { [[ "$1" == "curl" ]]; }   # curl present (probing possible), other tools missing
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

@test "_pf_memory: below floor on Linux -> hard fail + resize hint" {
  OS=Linux; _pf_total_mem_kb() { echo $((3 * 1024 * 1024)); }   # 3 GB
  run _pf_memory; [[ "$output" == *"to run the tracebloc client"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_memory: between floor and warn -> warn, no hard fail" {
  OS=Linux; _pf_total_mem_kb() { echo $((6 * 1024 * 1024)); }   # 6 GB
  run _pf_memory; [[ "$output" == *"recommended to train"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: ample RAM -> success" {
  OS=Linux; _pf_total_mem_kb() { echo $((16 * 1024 * 1024)); }
  run _pf_memory; [[ "$output" == *"16 GB"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: macOS below floor -> WARN only, never hard fail" {
  OS=Darwin; _pf_total_mem_kb() { echo $((3 * 1024 * 1024)); }
  run _pf_memory; [[ "$output" == *"Settings"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: 64 MiB grace -> a hair under the floor still passes" {
  OS=Linux; _pf_total_mem_kb() { echo $(( 5 * 1024 * 1024 - 1000 )); }   # ~5 GB minus a bit
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: PF_MIN_MEM_GB override relaxes the floor" {
  OS=Linux; PF_MIN_MEM_GB=2; PF_WARN_MEM_GB=2
  _pf_total_mem_kb() { echo $((3 * 1024 * 1024)); }   # 3 GB now passes
  run _pf_memory; [[ "$output" == *"3 GB"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_memory: Linux MemAvailable tight -> extra warn (total fine)" {
  OS=Linux; _pf_total_mem_kb() { echo $((16 * 1024 * 1024)); }   # total fine
  _pf_avail_mem_kb() { echo $((2 * 1024 * 1024)); }              # only 2 GB free now
  run _pf_memory; [[ "$output" == *"available right now"* ]]
  PF_HARD_FAIL=0; _pf_memory >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_cpu: too few cores -> warn" {
  _pf_ncpu() { echo 1; }
  run _pf_cpu; [[ "$output" == *"recommended"* ]]
}

@test "_pf_cpu: enough cores -> success" {
  _pf_ncpu() { echo 4; }
  run _pf_cpu; [[ "$output" == *"4 cores"* ]]
}

@test "_pf_cpu: between min and recommended -> warn (train), no hard fail" {
  _pf_ncpu() { echo 3; }
  run _pf_cpu; [[ "$output" == *"recommended to train"* ]]
  PF_HARD_FAIL=0; _pf_cpu >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]   # CPU never hard-fails
}

# ── selectors: container-runtime view preferred, host fallback ───────────────
@test "_pf_total_mem_kb: prefers runtime view over host (the Mac trap)" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"   # restore the real selectors
  _pf_runtime_mem_kb() { echo $((4 * 1024 * 1024)); }    # Docker VM = 4 GB
  _pf_host_mem_kb()    { echo $((36 * 1024 * 1024)); }   # host = 36 GB
  run _pf_total_mem_kb; [ "$output" -eq $((4 * 1024 * 1024)) ]
}

@test "_pf_total_mem_kb: falls back to host when runtime empty" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  _pf_runtime_mem_kb() { echo ""; }
  _pf_host_mem_kb()    { echo $((8 * 1024 * 1024)); }
  run _pf_total_mem_kb; [ "$output" -eq $((8 * 1024 * 1024)) ]
}

@test "_pf_ncpu: prefers runtime, falls back to host" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  _pf_runtime_ncpu() { echo 2; }; _pf_host_ncpu() { echo 16; }
  run _pf_ncpu; [ "$output" -eq 2 ]
  _pf_runtime_ncpu() { echo ""; }
  run _pf_ncpu; [ "$output" -eq 16 ]
}

@test "_pf_runtime_mem_kb: junk/zero MemTotal -> empty (forces fallback)" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  has() { return 0; }
  docker() { case "$*" in *MemTotal*) echo 0 ;; *) return 0 ;; esac; }
  run _pf_runtime_mem_kb; [ -z "$output" ]
}

# ── _pf_recheck_runtime_mem (post-Docker, warn-only) ─────────────────────────
@test "_pf_recheck_runtime_mem: small Docker VM -> warn, never hard fail" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  OS=Linux; _pf_runtime_mem_kb() { echo $((4 * 1024 * 1024)); }   # 4 GB Docker VM
  run _pf_recheck_runtime_mem; [[ "$output" == *"Docker is running with 4 GB"* ]]
  PF_HARD_FAIL=0; _pf_recheck_runtime_mem >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_recheck_runtime_mem: daemon not reporting -> silent no-op" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  _pf_runtime_mem_kb() { echo ""; }
  run _pf_recheck_runtime_mem; [ -z "$output" ]
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

# Code review: curl absent must SKIP connectivity (curl is installed downstream),
# not hard-fail with a misleading "egress blocked".
@test "_pf_connectivity: no curl -> warn + skip, not a hard fail" {
  has() { return 1; }
  run _pf_connectivity
  [[ "$output" == *"Skipping connectivity"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

# ── _pf_storage_type (network-FS guard for HOST_DATA_DIR) ────────────────────
# _pf_fstype is stubbed per-test; the storage check must reject network FSes but
# pass anything local — including overlay/tmpfs, which is what CI runners use.
@test "_pf_storage_type: local ext4 -> success, no hard fail" {
  _pf_fstype() { echo ext4; }
  run _pf_storage_type; [[ "$output" == *"ext4"* ]]
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_storage_type: overlay (CI/containers) -> success, never blocked" {
  _pf_fstype() { echo overlay; }
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_storage_type: NFS -> hard fail naming the cause + local-path hint" {
  _pf_fstype() { echo nfs; }
  run _pf_storage_type
  [[ "$output" == *"network filesystem (nfs)"* ]]
  [[ "$output" == *"HOST_DATA_DIR"* ]]
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_storage_type: NFS4 -> hard fail" {
  _pf_fstype() { echo nfs4; }
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_storage_type: CIFS -> hard fail" {
  _pf_fstype() { echo cifs; }
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_storage_type: fuse.sshfs -> hard fail (covers fuse.* network mounts)" {
  _pf_fstype() { echo fuse.sshfs; }
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
}

@test "_pf_storage_type: NFS + TRACEBLOC_ALLOW_NETWORK_FS -> warn, no hard fail" {
  _pf_fstype() { echo nfs; }; export TRACEBLOC_ALLOW_NETWORK_FS=1
  run _pf_storage_type; [[ "$output" == *"proceeding"* ]]
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
  unset TRACEBLOC_ALLOW_NETWORK_FS
}

@test "_pf_storage_type: undetermined fstype -> no hard fail (assume local)" {
  _pf_fstype() { echo ""; }
  PF_HARD_FAIL=0; _pf_storage_type >/dev/null; [ "$PF_HARD_FAIL" -eq 0 ]
}

# ── _pf_fstype reader (re-source for the real function) ──────────────────────
@test "_pf_fstype: lower-cases output and walks to the nearest existing parent" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  has() { [[ "$1" == "findmnt" ]]; }   # only findmnt 'present'
  findmnt() { echo NFS4; }             # upper-case, ignores args
  run _pf_fstype "${BATS_TEST_TMPDIR}/does/not/exist/yet"
  [ "$output" = "nfs4" ]
}

@test "_pf_fstype: real reader on this host -> a token or empty, never crashes" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  OS="$(uname -s)"
  run _pf_fstype /
  [ "$status" -eq 0 ]
  [[ -z "$output" || "$output" =~ ^[a-z0-9._/]+$ ]]
}
