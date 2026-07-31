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

@test "_pf_connectivity: Docker-engine host is WARN not hard — path-dependent (Bugbot #416)" {
  # The Docker install host varies by distro/path (Debian get.docker.com, RHEL
  # clones download.docker.com, Amazon/Arch/SUSE distro repos), so a blocked one
  # must NOT abort a supported install that never touches it — warn only.
  _pf_probe_url() { case "$1" in *get.docker.com*) echo blocked ;; *) echo ok ;; esac; }
  has() { [[ "$1" == "curl" ]]; }   # docker + all tools missing
  OS=Linux
  run _pf_connectivity
  [[ "$output" == *"get.docker.com) unreachable"* ]]                            # still surfaced…
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]   # …but NOT a hard fail
}

@test "_pf_connectivity: kubectl host (dl.k8s.io) blocked -> HARD fail (#416)" {
  _pf_probe_url() { case "$1" in *dl.k8s.io*) echo blocked ;; *) echo ok ;; esac; }
  has() { [[ "$1" == "curl" ]]; }   # tools missing -> their download hosts probed
  OS=Linux
  run _pf_connectivity
  [[ "$output" == *"dl.k8s.io) unreachable"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -ge 1 ]
}

@test "_pf_connectivity: k3d asset host objects.githubusercontent.com is probed (#416)" {
  # Release assets 302 to objects.githubusercontent.com; _pf_probe_url can't
  # follow redirects, so it must be listed (and probed) explicitly.
  _pf_probe_url() { case "$1" in *objects.githubusercontent.com*) echo blocked ;; *) echo ok ;; esac; }
  has() { [[ "$1" == "curl" ]]; }
  OS=Linux
  run _pf_connectivity
  [[ "$output" == *"objects.githubusercontent.com) unreachable"* ]]
}

@test "_pf_connectivity: auth.docker.io (Docker Hub token host) is probed hard (#416)" {
  _pf_probe_url() { case "$1" in *auth.docker.io*) echo blocked ;; *) echo ok ;; esac; }
  has() { return 0; }               # all tools present -> only always-critical hosts probed
  OS=Linux
  run _pf_connectivity
  [[ "$output" == *"auth.docker.io) unreachable"* ]]
}

@test "_pf_connectivity: macOS hard-probes formulae.brew.sh when a brew tool is absent (reviewer #416)" {
  # brew install pulls formula metadata from formulae.brew.sh even when brew is
  # already present — so a blocked metadata host must fail preflight, not the install.
  _pf_probe_url() { case "$1" in *formulae.brew.sh*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|brew|docker) return 0 ;; *) return 1 ;; esac; }  # brew+docker present, kubectl/k3d/helm absent
  OS=Darwin
  run _pf_connectivity
  [[ "$output" == *"formulae.brew.sh) unreachable"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -ge 1 ]
}

@test "_pf_connectivity: GUI Mac, only docker missing -> formulae.brew.sh NOT probed (Bugbot #416)" {
  # GUI Macs install Docker Desktop from desktop.docker.com, not brew — so docker
  # absence alone must not hard-fail the brew metadata host when the tools are present.
  _pf_probe_url() { case "$1" in *formulae.brew.sh*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|brew|kubectl|k3d|helm) return 0 ;; *) return 1 ;; esac; }  # only docker missing
  _pf_has_gui_session() { return 0; }   # GUI session -> Docker Desktop path
  OS=Darwin
  run _pf_connectivity
  [[ "$output" != *"formulae.brew.sh"* ]]              # not probed at all
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_connectivity: headless Mac, only docker missing -> formulae.brew.sh IS probed (Bugbot #416)" {
  # Headless Macs install colima/docker via brew, which hits formulae.brew.sh — so
  # a blocked metadata host must fail preflight on the Colima path.
  _pf_probe_url() { case "$1" in *formulae.brew.sh*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|brew|kubectl|k3d|helm) return 0 ;; *) return 1 ;; esac; }  # only docker missing
  _pf_has_gui_session() { return 1; }   # headless -> colima via brew
  OS=Darwin
  run _pf_connectivity
  [[ "$output" == *"formulae.brew.sh) unreachable"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -ge 1 ]
}

@test "_pf_connectivity: macOS hard-probes github.com for the Homebrew clone when brew absent (Bugbot #416)" {
  # install_homebrew git-clones Homebrew/brew from github.com after fetching the
  # script from raw.githubusercontent.com — both must be reachable.
  _pf_probe_url() { case "$1" in *//github.com/*) echo blocked ;; *) echo ok ;; esac; }
  has() { [[ "$1" == "curl" ]]; }   # brew missing -> clone host probed
  OS=Darwin
  run _pf_connectivity
  [[ "$output" == *"github.com) unreachable"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -ge 1 ]
}

@test "_pf_connectivity: GUI Mac, docker missing -> desktop.docker.com HARD (Bugbot #416)" {
  # Docker Desktop is the actual GUI-Mac Docker path, so a blocked CDN must fail
  # preflight, not the mid-download step.
  _pf_probe_url() { case "$1" in *desktop.docker.com*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|brew|kubectl|k3d|helm) return 0 ;; *) return 1 ;; esac; }  # only docker missing
  _pf_has_gui_session() { return 0; }   # GUI -> Docker Desktop
  OS=Darwin
  run _pf_connectivity
  [[ "$output" == *"desktop.docker.com) unreachable"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -ge 1 ]
}

@test "_pf_connectivity: headless Mac, docker missing -> desktop.docker.com NOT probed (Colima path; Bugbot #416)" {
  # Headless installs use colima/docker via brew, never desktop.docker.com — so a
  # blocked CDN must not abort that path (formulae.brew.sh covers the brew route).
  _pf_probe_url() { case "$1" in *desktop.docker.com*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|brew|kubectl|k3d|helm) return 0 ;; *) return 1 ;; esac; }  # only docker missing
  _pf_has_gui_session() { return 1; }   # headless -> colima via brew
  OS=Darwin
  run _pf_connectivity
  [[ "$output" != *"desktop.docker.com"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 0 ]
}

@test "_pf_connectivity: a download host is NOT probed when its tool is present (#416)" {
  _pf_probe_url() { case "$1" in *dl.k8s.io*) echo blocked ;; *) echo ok ;; esac; }
  has() { case "$1" in curl|kubectl) return 0 ;; *) return 1 ;; esac; }   # kubectl present
  OS=Linux
  run _pf_connectivity
  [[ "$output" != *"dl.k8s.io"* ]]  # present tool is never re-downloaded -> host not probed
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
@test "_pf_recheck_runtime_mem: sub-floor Docker VM -> HARD FAIL with the fix (#428)" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  OS=Darwin; _pf_runtime_mem_kb() { echo $((4 * 1024 * 1024)); }   # 4 GB VM < 5 GB floor
  error() { printf 'ERR: %s\n' "$*"; exit 1; }                     # real error() exits
  run _pf_recheck_runtime_mem
  [ "$status" -ne 0 ]
  [[ "$output" == *"below the ${PF_MIN_MEM_GB:-5} GB"* ]]
}
@test "_pf_recheck_runtime_mem: between floor and warn -> warn, no hard fail (#428)" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  OS=Linux; _pf_runtime_mem_kb() { echo $((6 * 1024 * 1024)); }   # 6 GB: >=5 floor, <8 warn
  error() { printf 'ERR: %s\n' "$*"; exit 1; }
  run _pf_recheck_runtime_mem
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker is running with 6 GB"* ]]
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

# strict mode (#385): content must exist — an HTTP error is a failure, not
# "reachable". Default mode is unchanged (404 still counts as reachable, e.g.
# registry endpoints that answer 401 by design).
@test "_pf_probe_url: strict maps HTTP errors to 'http <code>', 2xx to ok (#385)" {
  source "${BATS_TEST_DIRNAME}/../lib/preflight.sh"
  has() { return 0; }
  curl() { printf '404'; return 0; }; run _pf_probe_url https://x strict; [ "$output" = "http 404" ]
  curl() { printf '200'; return 0; }; run _pf_probe_url https://x strict; [ "$output" = "ok" ]
  curl() { printf '301'; return 0; }; run _pf_probe_url https://x strict; [ "$output" = "ok" ]
  curl() { printf '404'; return 0; }; run _pf_probe_url https://x;        [ "$output" = "ok" ]
  curl() { return 6;    };            run _pf_probe_url https://x strict; [ "$output" = "dns" ]
}

@test "_pf_connectivity: chart-repo index probed strictly — 404 hard-fails preflight (#385)" {
  _pf_probe_url() { case "${1}|${2:-}" in *index.yaml*\|strict) echo "http 404" ;; *) echo ok ;; esac; }
  run _pf_connectivity
  [[ "$output" == *"tracebloc Helm charts"* ]]
  [[ "$output" == *"http 404"* ]]
  PF_HARD_FAIL=0; _pf_connectivity >/dev/null 2>&1; [ "$PF_HARD_FAIL" -eq 1 ]
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
  # First-run copy: the visible line is the clean "Local storage (…)"; the fstype
  # detail (ext4) moved to the log, so assert the user-facing line, not the fstype.
  run _pf_storage_type; [[ "$output" == *"Local storage"* ]]
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

# ── first-run step a: collapsed hardware summary + connectivity combined line ─
@test "_pf_hw_summary_line: one line 'arch · N CPU cores · N GB memory · N GB free disk'" {
  ARCH=arm64; OS=Darwin
  _pf_ncpu() { echo 6; }
  _pf_total_mem_kb() { echo $((11 * 1024 * 1024)); }
  _pf_free_kb() { echo $((419 * 1024 * 1024)); }
  run _pf_hw_summary_line
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm64"* ]]
  [[ "$output" == *"6 CPU cores"* ]]
  [[ "$output" == *"11 GB memory"* ]]
  [[ "$output" == *"419 GB free disk"* ]]
}

@test "_pf_connectivity: all reachable -> single combined 'Connected:' line" {
  _pf_probe_url() { echo ok; }
  run _pf_connectivity
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected: tracebloc.io"* ]]
  [[ "$output" == *"Docker Hub (registry-1.docker.io)"* ]]
  [[ "$output" == *"GitHub (ghcr.io)"* ]]
}

@test "run_preflight: healthy -> collapsed step-a view, per-check ✔ lines folded away" {
  ARCH=arm64; OS=Darwin
  _pf_ncpu() { echo 6; }
  _pf_total_mem_kb() { echo $((11 * 1024 * 1024)); }
  _pf_free_kb() { echo $((419 * 1024 * 1024)); }
  _pf_fstype() { echo apfs; }
  _pf_probe_url() { echo ok; }
  HOST_DATA_DIR="$HOME/.tracebloc"
  run run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 CPU cores"* ]]        # collapsed hardware line
  [[ "$output" == *"Connected:"* ]]         # connectivity combined line
  [[ "$output" == *"Local storage"* ]]      # storage line
  # the individual arch/memory ✔ lines are suppressed inside run_preflight
  [[ "$output" != *"Architecture:"* ]]
  [[ "$output" != *"Memory:"* ]]
}

# ── early_data_dir_guard — pre-log network-FS refusal (#432) ─────────────────
@test "_pf_is_network_fstype: classifies network vs local" {
  _pf_is_network_fstype nfs4
  _pf_is_network_fstype cifs
  _pf_is_network_fstype fuse.sshfs
  ! _pf_is_network_fstype ext4
  ! _pf_is_network_fstype apfs
  ! _pf_is_network_fstype ""
}

@test "early_data_dir_guard: local filesystem -> silent pass" {
  _pf_fstype() { echo ext4; }
  run early_data_dir_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "early_data_dir_guard: undetermined filesystem -> pass (assume local)" {
  _pf_fstype() { echo ""; }
  run early_data_dir_guard
  [ "$status" -eq 0 ]
}

@test "early_data_dir_guard: NFS + existing data dir -> silent pass (healthy re-run reaches assess; Bugbot #441)" {
  _pf_fstype() { echo nfs4; }
  mkdir -p "$BATS_TEST_TMPDIR/existing/.tracebloc"
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/existing/.tracebloc" run early_data_dir_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "early_data_dir_guard: NFS -> refuses before any mkdir, names the fix" {
  _pf_fstype() { echo nfs4; }
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/fresh/.tracebloc" run early_data_dir_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"network filesystem (nfs4)"* ]]
  [[ "$output" == *"HOST_DATA_DIR"* ]]
  [[ "$output" == *"Refusing to create the data directory"* ]]
  # The remediation must be followable (Bugbot #441): validate_config rejects
  # paths outside $HOME, so the guard must not advise HOST_DATA_DIR=/local/path.
  [[ "$output" != *"/local/path"* ]]
  [[ "$output" == *"TRACEBLOC_ALLOW_NETWORK_FS=1"* ]]
  [[ "$output" == *"local disk"* ]]
}

@test "early_data_dir_guard: TRACEBLOC_ALLOW_NETWORK_FS defers to the full check" {
  _pf_fstype() { echo nfs4; }
  TRACEBLOC_ALLOW_NETWORK_FS=1 run early_data_dir_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "install-k8s.sh runs the early guard before setup_log_file (#432 ordering)" {
  local main_sh="$BATS_TEST_DIRNAME/../install-k8s.sh"
  local guard_line setup_line
  guard_line=$(grep -n 'early_data_dir_guard' "$main_sh" | head -1 | cut -d: -f1)
  setup_line=$(grep -n '^  setup_log_file' "$main_sh" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ -n "$setup_line" ]
  [ "$guard_line" -lt "$setup_line" ]
}

# ── #428: memory recommendation clamp + macOS VM sizing ─────────────────────
@test "_pf_clamp_mem_gb: clamps a recommendation to physical − reserve (#428)" {
  PF_OS_RESERVE_GB=2
  [ "$(_pf_clamp_mem_gb 16 16)" -eq 14 ]   # 16 GB Mac: can't recommend 16 -> 14
  [ "$(_pf_clamp_mem_gb 16 8)"  -eq 6  ]   # 8 GB Mac  -> 6
  [ "$(_pf_clamp_mem_gb 8  32)" -eq 8  ]   # plenty of headroom -> desired unchanged
}
@test "_pf_clamp_mem_gb: unknown physical -> desired unchanged (can't clamp) (#428)" {
  [ "$(_pf_clamp_mem_gb 16 0)" -eq 16 ]
  [ "$(_pf_clamp_mem_gb 16 '')" -eq 16 ]
}
@test "_macos_vm_mem_gb: derives min(half physical, clamped rec), floored (#428)" {
  PF_MIN_MEM_GB=5; PF_WARN_MEM_GB=8; PF_REC_MEM_GB=16; PF_OS_RESERVE_GB=2
  [ "$(_macos_vm_mem_gb 8)"  -eq 5  ]   # half=4 -> floored to 5 (workable on an 8 GB Mac)
  [ "$(_macos_vm_mem_gb 16)" -eq 8  ]   # half=8, rec clamped 14 -> 8
  [ "$(_macos_vm_mem_gb 64)" -eq 16 ]   # half=32, rec 16 -> 16 (capped at rec)
}
@test "_macos_vm_mem_gb: unknown physical -> COLIMA_MEMORY default (#428)" {
  COLIMA_MEMORY=6
  [ "$(_macos_vm_mem_gb 0)" -eq 6 ]
}

@test "setup-macos.sh colima memory is DERIVED via _macos_vm_mem_gb, not hard-coded 6 (#428)" {
  f="$BATS_TEST_DIRNAME/../lib/setup-macos.sh"
  grep -qE 'COLIMA_MEMORY:-\$\(_macos_vm_mem_gb\)' "$f"
  ! grep -qE '\-\-memory "\$\{COLIMA_MEMORY:-6\}"' "$f"   # the old hard-coded 6 is gone
}
