#!/usr/bin/env bash
# =============================================================================
#  preflight.sh — fail-fast environment checks (arch, egress, disk, RAM, CPU)
#
#  Runs before any install/cluster work. Each check prints a ✔/⚠/✖ line; hard
#  failures are AGGREGATED so the user sees every problem at once, then we exit
#  ONCE with a summary. The goal: a run that can't succeed fails in seconds with
#  a precise, actionable reason instead of a cryptic crash minutes in.
#
#  Escape hatches:
#    TRACEBLOC_SKIP_PREFLIGHT=1   skip all checks
#    TRACEBLOC_ALLOW_ARM64=1      proceed on arm64 despite amd64-only images
#    TRACEBLOC_ALLOW_NETWORK_FS=1 proceed when HOST_DATA_DIR is on NFS/CIFS/SMB (DB may corrupt)
#    PF_MIN_MEM_GB / PF_MIN_CPU / PF_MIN_DISK_GB   lower the hard floors (CI / odd sites)
#
#  This file is side-effect-safe to source (defaults + function defs only).
# =============================================================================

# Thresholds (overridable via env — for unusual sites or tests).
# RAM floors are derived from the real stack, not guessed: the always-on control
# plane requests ~2.1 GiB, + k3s/k3d ~0.8 + OS/Docker ~0.7 ≈ ~4.4 GiB just to stay
# Online on a single-node (k3d) install — so below 5 GiB it boots then OOMs. 8 GiB
# is comfortable to run; 16 GiB is needed to train locally (a job's limit is ~8 GiB+).
PF_MIN_DISK_GB="${PF_MIN_DISK_GB:-10}"     # hard-fail below this (Linux) — base images alone need >5
PF_WARN_DISK_GB="${PF_WARN_DISK_GB:-20}"   # warn below this
PF_MIN_MEM_GB="${PF_MIN_MEM_GB:-5}"        # hard-fail below this (Linux; warn on Mac/Win)
PF_WARN_MEM_GB="${PF_WARN_MEM_GB:-8}"      # warn below this (comfortable to run)
PF_REC_MEM_GB="${PF_REC_MEM_GB:-16}"       # recommended to train locally (copy only, not a gate)
PF_OS_RESERVE_GB="${PF_OS_RESERVE_GB:-2}"  # RAM to leave the OS — recommendations clamp at physical − this (#428)
# A guest VM's reported MemTotal runs a few hundred MiB below its CONFIGURED size
# (kernel/reserved). The runtime recheck sees the GUEST figure, so it tolerates this
# much below the floor — otherwise a Docker Desktop VM set to exactly the documented
# floor would hard-fail on the guest shortfall, making the effective floor a GB higher
# than we tell people (#513 reviewer). 512 MiB comfortably covers the observed gap.
PF_VM_MEM_GRACE_MIB="${PF_VM_MEM_GRACE_MIB:-512}"
PF_MIN_CPU="${PF_MIN_CPU:-2}"              # warn below this
PF_REC_CPU="${PF_REC_CPU:-4}"              # recommended (warn) below this

# Non-exiting failure line (common.sh's error() exits; preflight must finish all
# checks first, so failures print here and are recorded in PF_HARD_FAIL). Writes
# to stdout (like warn/success/info) so it stays ordered with the hint() lines
# that follow — only the final aggregated error() writes to stderr.
_pf_fail_line() { echo -e "  ${RED}✖${RESET} $*"; }

# Quiet-success helpers (first-run run-through). run_preflight sets
# PF_QUIET_SUCCESS while the arch/CPU/RAM/disk checks run, so their individual
# ✔ lines are SUPPRESSED and collapsed into one summary line
# ("arch · N CPU cores · N GB memory · N GB free disk"); warnings and hard-fails
# still print. When called directly (the bats suite, or the direct-invocation
# path) the flag is unset and the per-check ✔/info lines print as before, so the
# unit tests that assert on them keep passing. Connectivity + storage print their
# own always-on summary line and so do NOT route through these.
_pf_ok()   { [[ -n "${PF_QUIET_SUCCESS:-}" ]] || success "$*"; }
_pf_note() { [[ -n "${PF_QUIET_SUCCESS:-}" ]] || info "$*"; }

# ── Injectable readers (overridden in bats so checks run without net/df) ─────

# Probe a URL for reachability. Echoes one of: ok|dns|refused|timeout|tls|blocked|nocurl
# (or "http <code>" in strict mode). "Reachable" = any HTTP response (200/401/403 all
# count — TLS + HTTP completed). Pass "strict" as $2 for targets whose CONTENT must
# exist (2xx/3xx only — e.g. the Helm repo index.yaml, where the site root 404s by
# design and plain reachability proves nothing, #385).
# Respects the caller's HTTP(S)_PROXY env (curl picks it up), so a TLS-inspecting
# proxy without its CA surfaces here as 'tls'.
_pf_probe_url() {
  local url="$1" mode="${2:-}" code ec
  has curl || { echo "nocurl"; return 0; }
  code=$(curl_secure -sS -o /dev/null --max-time 8 -w '%{http_code}' "$url" 2>/dev/null) && ec=0 || ec=$?
  if [[ -n "$code" && "$code" != "000" ]]; then
    if [[ "$mode" == "strict" && ! "$code" =~ ^[23] ]]; then echo "http $code"; return 0; fi
    echo "ok"; return 0
  fi
  case "${ec:-1}" in
    6)     echo "dns" ;;
    7)     echo "refused" ;;
    28)    echo "timeout" ;;
    35|60) echo "tls" ;;
    *)     echo "blocked" ;;
  esac
  return 0
}

# Free space in KB on the filesystem holding $1.
_pf_free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# Filesystem type holding $1, lower-cased (e.g. ext4, xfs, apfs, overlay, nfs,
# nfs4, cifs, smbfs), or empty if undeterminable. $1 may not exist yet at
# preflight, so walk up to the nearest existing parent. Tries findmnt (util-linux,
# bind-mount aware), then GNU `stat -f` (Linux only — BSD/macOS `stat -f` means
# "format string", not filesystem), then df+mount (portable, incl. macOS).
_pf_fstype() {
  local p="$1" parent t="" mp
  while [[ -n "$p" && ! -e "$p" ]]; do
    parent="$(dirname "$p")"
    [[ "$parent" == "$p" ]] && break
    p="$parent"
  done
  [[ -z "$p" || ! -e "$p" ]] && return 0
  if has findmnt; then
    t="$(findmnt -nro FSTYPE --target "$p" 2>/dev/null | head -1)"
  fi
  if [[ -z "$t" && "$OS" != "Darwin" ]]; then
    t="$(stat -f -c '%T' "$p" 2>/dev/null)"
  fi
  if [[ -z "$t" ]] && has df; then
    mp="$(df "$p" 2>/dev/null | awk 'NR>1 && $NF ~ /^\// {print $NF}' | tail -1)"
    [[ -n "$mp" ]] && t="$(mount 2>/dev/null | awk -v m="$mp" 'index($0," on "m" (")>0 {sub(/.* \(/,""); sub(/[,)].*/,""); print; exit}')"
  fi
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]'
}

# Memory/CPU as the CONTAINER RUNTIME sees it (the budget the pods actually get).
# On Docker Desktop / Colima / WSL2 this is the VM's allocation — smaller than the
# host and the number that matters (a 36 GB Mac can cap its Docker VM at 4 GB). Echo
# a single integer, or nothing if the daemon is down / the value is junk — callers
# then fall back to the host reader. (docker info precedent: _pf_docker_root above.)
_pf_runtime_mem_kb() {
  has docker && docker info >/dev/null 2>&1 || return 0
  local b; b="$(docker info --format '{{.MemTotal}}' 2>/dev/null)"
  [[ "$b" =~ ^[0-9]+$ && "$b" -gt 0 ]] && echo $(( b / 1024 ))
  return 0
}
_pf_runtime_ncpu() {
  has docker && docker info >/dev/null 2>&1 || return 0
  local n; n="$(docker info --format '{{.NCPU}}' 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] && echo "$n"
  return 0
}

# Total physical RAM of the HOST in KB.
_pf_host_mem_kb() {
  if [[ "$OS" == "Darwin" ]]; then
    local b; b=$(sysctl -n hw.memsize 2>/dev/null) || b=""
    [[ -n "$b" ]] && echo $(( b / 1024 ))
  else
    awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null
  fi
}

# Host physical RAM in whole GB (0 when undeterminable). (#428)
_pf_host_mem_gb() {
  local kb; kb="$(_pf_host_mem_kb)"
  [[ "$kb" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  printf '%s' "$(( kb / 1024 / 1024 ))"
}

# Clamp a DESIRED memory figure (GB) so a hint never exceeds this machine (#428):
# min(DESIRED, physical − PF_OS_RESERVE_GB), but NEVER below PF_MIN_MEM_GB — the client
# needs the floor to run, so a hint must never tell the operator to "raise to" a
# sub-floor number (Bugbot). "raise to 16 GB" on a 16 GB Mac is impossible; "raise to
# 4 GB" on a 6 GB Mac is nonsensical (below the floor AND their RAM). Physical unknown/0
# -> DESIRED (can't clamp). Args: DESIRED [physical GB (default: host)].
_pf_clamp_mem_gb() {
  local desired="$1" phys="${2:-$(_pf_host_mem_gb)}" cap
  [[ "$phys" =~ ^[0-9]+$ && "$phys" -gt 0 ]] || { printf '%s' "$desired"; return 0; }
  cap=$(( phys - PF_OS_RESERVE_GB )); (( cap < PF_MIN_MEM_GB )) && cap=$PF_MIN_MEM_GB
  if (( desired < cap )); then printf '%s' "$desired"; else printf '%s' "$cap"; fi
}

# The memory budget (GB) to give a macOS VM (colima / Docker Desktop), derived from
# physical RAM (#428): min(half of physical, the clamped recommendation), never below
# the client floor PF_MIN_MEM_GB. The single sizing helper both macOS paths share.
# Physical unknown/0 -> the historic COLIMA_MEMORY default. Arg: physical GB (default: host).
_macos_vm_mem_gb() {
  local phys="${1:-$(_pf_host_mem_gb)}" half rec budget safe_floor cap
  [[ "$phys" =~ ^[0-9]+$ && "$phys" -gt 0 ]] || { printf '%s' "${COLIMA_MEMORY:-6}"; return 0; }
  half=$(( phys / 2 ))
  rec="$(_pf_clamp_mem_gb "$PF_REC_MEM_GB" "$phys")"
  budget=$(( half < rec ? half : rec ))
  # Never size EXACTLY to the floor: the guest MemTotal runs a few hundred MiB below
  # the configured VM size, so a floor-sized VM boots then trips the runtime recheck's
  # sub-floor hard-fail on its OWN choice (#428 Bugbot). Give ≥ 1 GB of headroom above
  # the floor — but never over-commit the host (cap at physical − reserve); a host too
  # small for that gets less, and the recheck then stops it honestly as "too small".
  safe_floor=$(( PF_MIN_MEM_GB + 1 ))
  cap=$(( phys - PF_OS_RESERVE_GB ))
  (( budget < safe_floor )) && budget=$safe_floor
  (( budget > cap )) && budget=$cap
  (( budget < 1 )) && budget=1
  printf '%s' "$budget"
}

# Logical CPU count of the HOST.
_pf_host_ncpu() {
  if [[ "$OS" == "Darwin" ]]; then
    sysctl -n hw.ncpu 2>/dev/null
  else
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null
  fi
}

# Available (free) RAM right now, KB — Linux only (for the busy-shared-VM warn).
_pf_avail_mem_kb() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null; }

# True on a macOS box with a real GUI login session — mirrors setup-macos.sh's
# _has_gui_session (the branch that installs Docker Desktop from desktop.docker.com
# vs. the headless branch that installs colima/docker via brew). /dev/console is
# owned by the GUI user; on headless Macs (EC2/CI) it's "root" or empty. Used to
# decide whether a missing docker means a brew install (→ formulae.brew.sh needed).
_pf_has_gui_session() {
  local u; u="$(stat -f '%Su' /dev/console 2>/dev/null || echo '')"
  [[ -n "$u" && "$u" != "root" ]]
}

# Selectors: prefer the runtime view, fall back to the host. The checks (and the
# bats numeric test) call these names; they always emit exactly one integer.
#
# There is deliberately NO _pf_total_mem_kb "prefer the runtime" memory selector
# (#417): conflating the two numbers made the SAME machine report "16 GB (host)"
# on a cold run and "6 GB (Docker VM)" on a warm one. Memory has two distinct
# truths and each caller must name the one it means — _pf_host_mem_kb for a
# hardware fact, _pf_runtime_mem_kb for the budget the pods actually get.
# CPU keeps the fallback selector: there is no equivalent advice split.
_pf_ncpu()         { local v; v="$(_pf_runtime_ncpu)";   [[ -n "$v" ]] && { echo "$v"; return 0; }; _pf_host_ncpu; }

# The ONE copy AND the one grading threshold for the Docker-budget line (#417),
# used by BOTH _pf_memory (Docker already up on a warm re-run) and the post-Docker
# recheck. The two used to print diverging text for the identical condition, and
# because they also compared against DIFFERENT thresholds — the helper against the
# clamped target, the recheck against the raw PF_WARN_MEM_GB — one run could print
# "✔ Docker's memory budget: 6 GB" and then "⚠ recommended ≥ 6 GB" about the very
# same budget (Bugbot #445 r2). Grading lives here only.
#
# Takes MiB, not GB, so it uses the SAME PF_VM_MEM_GRACE_MIB tolerance as the
# recheck: a VM configured to exactly the documented floor reports a few hundred
# MiB less as guest MemTotal, and rounding that to whole GB first would misgrade it
# as sub-floor.
#
# WARN-ONLY by design; the sub-floor HARD-FAIL stays in _pf_recheck_runtime_mem,
# the only place the real VM size is known (#428/#513). Sets
# PF_RUNTIME_MEM_WARNED so one run never warns twice about the same budget — that
# latch suppresses a duplicate WARNING only and must never gate the hard-fail.
# Args: the runtime budget in MiB, and optionally "quiet_ok" to suppress the ✔
# line when the budget is fine — the post-Docker recheck passes it so a healthy
# install doesn't print the same ✔ twice (preflight already said it on a warm run).
# True when the MACHINE cannot give Docker the floor while leaving the OS its
# reserve. No Docker setting fixes that, so both the machine line (_pf_memory) and
# the budget remedy (_pf_runtime_mem_status) must reach the same verdict from ONE
# definition — a 5-6 GB host was being graded "enough to run" on one line and told
# to "use a larger machine" two lines later, in the same preflight (Bugbot #445 r3).
_pf_host_too_small_for_floor() {
  local host_gb="${1:-}"
  [[ "$host_gb" =~ ^[0-9]+$ ]] || return 1
  (( host_gb > 0 )) || return 1
  (( host_gb - PF_OS_RESERVE_GB < PF_MIN_MEM_GB ))
}

_pf_runtime_mem_status() {
  local rt_mib="$1" quiet_ok="${2:-}" rt_gb warn_eff rec_eff host_gb target_gb
  # Report the CONFIGURED size, not the guest-visible one. A VM asked for N GB
  # reports a few hundred MiB less as MemTotal (kernel + firmware reservations),
  # so plain rt_mib/1024 showed a VM set to exactly the documented floor as one
  # GB BELOW it — graded correctly by the grace-aware thresholds below, but
  # displayed as if sub-floor, which reads as a contradiction. Adding the same
  # grace before the division recovers the configured figure. Mirrors the
  # PowerShell peer's (mib + grace) / 1024 (Bugbot #445 r3).
  rt_gb=$(( (rt_mib + PF_VM_MEM_GRACE_MIB) / 1024 ))
  warn_eff="$(_pf_clamp_mem_gb "$PF_WARN_MEM_GB")"
  rec_eff="$(_pf_clamp_mem_gb "$PF_REC_MEM_GB")"
  if (( rt_mib < PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB )); then
    warn "Docker's memory budget: ${rt_gb} GB — below the ${PF_MIN_MEM_GB} GB the client needs; it will OOM."
    # Sub-floor is the ONE condition where _pf_recheck_runtime_mem also hard-fails
    # (the latch suppresses a duplicate warning, never the hard-fail), so this
    # remedy has to quote the SAME size that failure quotes or one install prints
    # two different targets for one problem — the diverging-copy bug this change
    # exists to remove, which survived on exactly this path (Bugbot #445 r3).
    target_gb="$warn_eff"
  # The WARN threshold carries the grace too, not just the floor one. The shown
  # figure is now (mib + grace)/1024, so grading this branch on the raw threshold
  # reopened the same self-contradiction one boundary up: every budget in
  # [warn*1024 - grace, warn*1024) — 7680..8191 MiB at warn 8, a band Docker
  # Desktop's own defaults land in — printed "budget: 8 GB — recommended ≥ 8 GB".
  # With both the display and both thresholds pivoting on the grace, shown == target
  # implies the ✔ branch, so no displayed number can contradict its own grade.
  elif (( rt_mib < warn_eff * 1024 - PF_VM_MEM_GRACE_MIB )); then
    warn "Docker's memory budget: ${rt_gb} GB — recommended ≥ ${warn_eff} GB (${rec_eff} GB to train); the client may OOM under load."
    # No hard-fail follows this branch, so the remedy can aim at the train figure.
    target_gb="$rec_eff"
  else
    [[ -n "$quiet_ok" ]] || _pf_ok "Docker's memory budget: ${rt_gb} GB"
    return 0
  fi
  # A machine that cannot reach the floor even with the OS reserve honoured is too
  # small for tracebloc no matter how Docker is configured, so a "give Docker N GB"
  # remedy is a dead end that asks for more than the machine has (Bugbot #445 r2 —
  # a 4 GB Mac was told "colima start --memory 5"). Say so plainly instead; the
  # recheck's own host-too-small branch then stops the install honestly. Mirrors
  # the PowerShell installer's host-too-small branch (#444).
  host_gb="$(_pf_host_mem_gb)"
  if _pf_host_too_small_for_floor "$host_gb"; then
    hint "This machine has ${host_gb} GB of RAM total; the client needs a ${PF_MIN_MEM_GB} GB Docker budget and the OS needs ~${PF_OS_RESERVE_GB} GB. Free up memory or use a larger machine."
  elif [[ "$OS" == "Darwin" ]]; then
    hint "Give Docker ${target_gb} GB: Docker Desktop → Settings → Resources → Memory (colima: colima stop && colima start --memory ${target_gb})."
  else
    # No Docker Desktop dead end on Linux (Bugbot #445): headless/engine-only
    # boxes have no Desktop UI — a low budget there is the machine's RAM or a
    # VM/cgroup limit.
    hint "Give Docker ${target_gb} GB: on Linux this budget is the machine's RAM or a VM/cgroup limit — raise that limit or free memory, then restart Docker."
  fi
  PF_RUNTIME_MEM_WARNED=1
  return 0
}

# Docker data root if the daemon is up; else where it will live / a host proxy.
_pf_docker_root() {
  if has docker && docker info >/dev/null 2>&1; then
    docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker"
  elif [[ "$OS" == "Linux" ]]; then
    echo "/var/lib/docker"
  else
    echo "$HOME"
  fi
}

# Backend host per CLIENT_ENV (mirrors install-client-helm.sh::_backend_url;
# inlined so preflight is self-contained + unit-testable in isolation).
_pf_backend_host() {
  case "${CLIENT_ENV:-prod}" in
    dev) echo "dev-api.tracebloc.io" ;;
    stg) echo "stg-api.tracebloc.io" ;;
    *)   echo "api.tracebloc.io" ;;
  esac
}

# ── Checks (each ALWAYS returns 0; hard failures go into PF_HARD_FAILS) ───────

# True if the host can run amd64 binaries via QEMU binfmt (wrapped for testing).
_pf_amd64_emulation_available() { [[ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]]; }

_pf_arch() {
  case "$ARCH" in
    x86_64|amd64) _pf_ok "Architecture: ${ARCH} (amd64)"; return 0 ;;
  esac
  # Non-amd64 (arm64/aarch64): the tracebloc client images (e.g. mysql-client)
  # are amd64-only, so they need emulation to run.
  if [[ -n "${TRACEBLOC_ALLOW_ARM64:-}" ]]; then
    warn "Architecture: ${ARCH} — proceeding (TRACEBLOC_ALLOW_ARM64 set); amd64-only images may crash if emulation is unavailable."
    return 0
  fi
  if [[ "$OS" != "Linux" ]]; then
    # Don't ASSUME emulation works here — Docker isn't up yet at preflight, so the real
    # amd64 smoke runs post-Docker (assert_amd64_emulation, #433). Name the setting now
    # so the operator can pre-empt it.
    _pf_note "Architecture: ${ARCH} — the amd64 client images run under emulation; Docker's \"Use Rosetta for x86_64/amd64 emulation\" must be enabled (verified once Docker is running)."
    return 0
  fi
  if _pf_amd64_emulation_available; then
    _pf_note "Architecture: ${ARCH} — amd64 emulation (QEMU binfmt) available; client images run emulated (slower)."
    return 0
  fi
  _pf_fail_line "Architecture: ${ARCH} — the tracebloc client images (e.g. mysql-client) are amd64-only and can't run here."
  PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
  hint "Fix: provision an amd64 (x86_64) VM, or enable emulation and re-run:"
  hint "  docker run --privileged --rm tonistiigi/binfmt --install amd64"
  hint "  (or set TRACEBLOC_ALLOW_ARM64=1 to proceed anyway)"
  return 0
}

_pf_cpu() {
  local n; n="$(_pf_ncpu)"
  if [[ -z "$n" ]]; then warn "CPU: couldn't determine core count (skipping)."; return 0; fi
  # CPU is warn-only: starvation throttles (and can trip mysql InnoDB lock-wait
  # timeouts) but doesn't OOM-kill, and the chart deliberately omits limits.cpu.
  if [[ "$n" -lt "$PF_MIN_CPU" ]]; then
    warn "CPU: ${n} core(s) — below the ${PF_MIN_CPU}-core minimum; mysql may hit lock-wait timeouts. ${PF_REC_CPU}+ recommended to train."
  elif [[ "$n" -lt "$PF_REC_CPU" ]]; then
    warn "CPU: ${n} cores — fine to run; ${PF_REC_CPU}+ recommended to train locally."
  else
    _pf_ok "CPU: ${n} cores"
  fi
  return 0
}

_pf_memory() {
  # Two truths, two lines (#417): the machine's RAM (a hardware fact — the gate
  # runs on it; on native Linux the daemon sees all host RAM so the gate is
  # unchanged) and, when a runtime VM is up with a meaningfully smaller budget
  # (macOS Docker Desktop / colima, WSL2), Docker's actual budget on its own
  # line with achievable advice. The old single line flip-flopped between the
  # two across re-runs of the SAME installer on the SAME machine — "16 GB
  # (host)" cold, "6 GB (Docker VM)" warm — depending only on whether Docker
  # happened to already be running.
  local host_kb rt_kb rt_gb kb gb mib floor_mib warn_mib label rec_gb warn_gb
  host_kb="$(_pf_host_mem_kb)"
  rt_kb="$(_pf_runtime_mem_kb)"
  [[ -n "$rt_kb" ]] && rt_gb=$(( rt_kb / 1024 / 1024 ))
  # Gate on the machine; only if the host is unreadable fall back to the VM
  # budget (rare — /proc/meminfo and hw.memsize are near-universal).
  kb="$host_kb"; label="machine"
  if [[ -z "$kb" && -n "$rt_kb" ]]; then kb="$rt_kb"; label="Docker VM"; fi
  if [[ -z "$kb" ]]; then warn "Memory: couldn't determine total RAM (skipping)."; return 0; fi
  mib=$(( kb / 1024 ))
  # Same grace-adjusted figure _pf_runtime_mem_status reports, so one budget never
  # appears as two different numbers across the two messages (Bugbot #445 r4).
  gb=$(( (mib + PF_VM_MEM_GRACE_MIB) / 1024 ))
  # Compare in MiB with a 64 MiB grace so a VM that reports e.g. 4 GiB a hair under
  # 4*1024^3 (Colima / Docker Desktop) doesn't floor to 3 GB and false-trip the gate.
  # Tolerance must match the grace already applied to the SHOWN figure above, or
  # the two disagree: a 5 GB VM whose MemTotal sits a few hundred MiB under the
  # configured size displayed as "5 GB" while a 64 MiB tolerance graded it
  # sub-floor, producing "Memory: 5 GB — below the 5 GB the client needs"
  # (Bugbot #445 r5, High). PF_VM_MEM_GRACE_MIB is the same tolerance
  # _pf_runtime_mem_status uses for its own floor and warn tests, so all three
  # now agree on where the boundaries are.
  floor_mib=$(( PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB ))
  warn_mib=$(( PF_WARN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB ))
  # SHOWN figures clamped to physical RAM so no hint asks for more than the machine
  # has (#428): "raise to 16 GB" on a 16 GB Mac is impossible.
  rec_gb="$(_pf_clamp_mem_gb "$PF_REC_MEM_GB")"
  warn_gb="$(_pf_clamp_mem_gb "$PF_WARN_MEM_GB")"

  if [[ "$mib" -lt "$floor_mib" ]]; then
    if [[ "$OS" == "Linux" ]]; then
      _pf_fail_line "Memory: only ${gb} GB (${label}) — need ≥ ${PF_MIN_MEM_GB} GB to run the tracebloc client."
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      hint "Resize the VM (or free memory) to ≥ ${warn_gb} GB; ${rec_gb} GB to train locally. Then re-run."
    else
      # Mac/Win: the MACHINE itself is below the floor — no Docker setting can
      # fix that, so don't offer a resize remedy here. Warn (don't block); the
      # create_cluster re-check sees the real VM size and HARD-FAILS a sub-floor
      # VM (#428), including the honest "use a larger machine" case.
      warn "Memory: ${gb} GB (${label}) — below the ${PF_MIN_MEM_GB} GB the client needs; it will OOM."
    fi
  elif [[ "$OS" != "Linux" && "$label" == "machine" ]] \
     && _pf_host_too_small_for_floor "$(_pf_host_mem_gb)"; then
    # Above the bare floor, but not by enough to give Docker the floor AND leave
    # the OS its reserve. Saying "enough to run" here contradicted the budget
    # line's "use a larger machine" in the same preflight (Bugbot #445 r3). On
    # native Linux the daemon sees host RAM directly, so the reserve arithmetic
    # does not apply and that path keeps the original wording.
    warn "Memory: ${gb} GB (${label}) — the client needs a ${PF_MIN_MEM_GB} GB Docker budget and the OS needs ~${PF_OS_RESERVE_GB} GB, so this machine is below the practical minimum of about $(( PF_MIN_MEM_GB + PF_OS_RESERVE_GB )) GB. Free up memory or use a larger machine."
  elif [[ "$mib" -lt "$warn_mib" ]]; then
    warn "Memory: ${gb} GB (${label}) — enough to run, but training (≈8 GB/job) may OOM; ${rec_gb} GB of RAM recommended to train locally."
  else
    _pf_ok "Memory: ${gb} GB (${label})"
  fi

  # Docker's budget as its own line — only when a runtime is up AND its budget is
  # meaningfully smaller than the machine (the VM case). On native Linux the
  # daemon sees host RAM, so this would just repeat the line above.
  if [[ -n "$rt_kb" && "$label" == "machine" ]] && (( rt_gb + 1 < gb )); then
    _pf_runtime_mem_status $(( rt_kb / 1024 ))
  fi

  # Linux: even when total is fine, a busy shared VM may have little free RAM now.
  if [[ "$OS" == "Linux" ]]; then
    local avail_kb avail_gb
    avail_kb="$(_pf_avail_mem_kb)"
    if [[ -n "$avail_kb" ]]; then
      avail_gb=$(( avail_kb / 1024 / 1024 ))
      if [[ "$avail_gb" -lt "$PF_MIN_MEM_GB" ]]; then
        warn "Memory: only ${avail_gb} GB available right now (other workloads are using this machine) — the client needs ~${PF_MIN_MEM_GB} GB free to start."
      fi
    fi
  fi
  return 0
}

# Re-evaluate memory once Docker is confirmed up. Preflight runs before Docker
# starts (install-k8s.sh), so on macOS/Windows the first read was host RAM, not the
# Docker VM's smaller budget. Called from create_cluster (cluster.sh) — the first
# point `docker info` is reliably up on every OS. A sub-FLOOR VM HARD-FAILS here with
# the exact fix (#428): it will OOM-crashloop the client, so proceeding is worse than
# the jarring stop the WARN path used to avoid. A between-floor-and-warn VM still only
# warns (the user has waited for Docker; it can run, just tightly).
_pf_recheck_runtime_mem() {
  [[ -n "${TRACEBLOC_SKIP_PREFLIGHT:-}" ]] && return 0
  # rec_gb is deliberately not read here: the between-floor-and-warn copy (and its
  # "N GB to train" figure) now lives solely in _pf_runtime_mem_status.
  local kb gb mib warn_gb; kb="$(_pf_runtime_mem_kb)"
  [[ -z "$kb" ]] && return 0          # daemon still not reporting — nothing to add
  gb=$(( kb / 1024 / 1024 ))
  mib=$(( kb / 1024 ))
  warn_gb="$(_pf_clamp_mem_gb "$PF_WARN_MEM_GB")"
  if [[ "$mib" -lt $(( PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB )) ]]; then
    # The REAL VM size is now known and it's below the floor — the client OOMs. Stop.
    # Tolerance is PF_VM_MEM_GRACE_MIB (not 64): the guest MemTotal is a few hundred MiB
    # under the configured size, so a VM set to exactly the documented floor still
    # passes here rather than hard-failing on the guest shortfall (#513 reviewer).
    # If the HOST is too small to ever give the VM the floor (physical − reserve <
    # floor), no resize helps — say so plainly instead of a remedy that repeats an
    # unachievable size (#428 Bugbot; mirrors the PowerShell host-too-small branch).
    local phys_gb; phys_gb="$(_pf_host_mem_gb)"
    if [[ "$OS" != "Linux" && "$phys_gb" =~ ^[0-9]+$ && "$phys_gb" -gt 0 && $(( phys_gb - PF_OS_RESERVE_GB )) -lt PF_MIN_MEM_GB ]]; then
      error "This Mac has ${phys_gb} GB RAM — too little for tracebloc: the client needs a ${PF_MIN_MEM_GB} GB Docker VM and macOS needs ~${PF_OS_RESERVE_GB} GB, so about $(( PF_MIN_MEM_GB + PF_OS_RESERVE_GB )) GB physical is the practical minimum. Use a larger machine."
    elif [[ "$OS" == "Linux" ]]; then
      error "Docker has only ${gb} GB — below the ${PF_MIN_MEM_GB} GB the tracebloc client needs; it will OOM. Free memory (or raise the VM) to ≥ ${warn_gb} GB, then re-run."
    else
      error "Docker's VM has only ${gb} GB — below the ${PF_MIN_MEM_GB} GB the tracebloc client needs; it will OOM. Raise it: Docker Desktop → Settings → Resources → Memory ≥ ${warn_gb} GB (or colima: colima stop && colima start --memory ${warn_gb}), then re-run."
    fi
  fi
  # Between floor and warn: warn only, through the ONE shared copy so this and the
  # Step-1 preflight line can no longer diverge in wording OR in threshold — the
  # cold-install path (Docker starts mid-run, the common case) previously got its
  # own text with no colima guidance and no Linux cgroup hint, and graded against
  # the raw PF_WARN_MEM_GB while preflight used the clamped target (Bugbot #445 r2).
  # Skipped when preflight ALREADY reported this same budget on a warm re-run. The
  # latch suppresses a DUPLICATE WARNING only, and is deliberately tested here
  # rather than at the top of the function so it can never gate the hard-fail above.
  if [[ -z "${PF_RUNTIME_MEM_WARNED:-}" ]]; then
    _pf_runtime_mem_status "$mib" quiet_ok
  fi
  return 0
}

_pf_disk() {
  local target free_kb free_gb
  target="$(_pf_docker_root)"
  if [[ ! -d "$target" ]]; then target="/"; fi
  if [[ "$OS" != "Linux" ]]; then target="$HOME"; fi   # Desktop VM disk is opaque
  free_kb="$(_pf_free_kb "$target")"
  if [[ -z "$free_kb" ]]; then warn "Disk: couldn't determine free space on ${target} (skipping)."; return 0; fi
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "$OS" != "Linux" ]]; then
    _pf_note "Disk: ${free_gb} GB free on ${target} (host) — also ensure Docker Desktop's disk image has ≥ ${PF_WARN_DISK_GB} GB."
    return 0
  fi
  if [[ "$free_gb" -lt "$PF_MIN_DISK_GB" ]]; then
    _pf_fail_line "Disk: only ${free_gb} GB free on ${target} — need ≥ ${PF_MIN_DISK_GB} GB."
    PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
    hint "Free up space or attach a larger disk, then re-run."
  elif [[ "$free_gb" -lt "$PF_WARN_DISK_GB" ]]; then
    warn "Disk: ${free_gb} GB free on ${target} — recommended ≥ ${PF_WARN_DISK_GB} GB; images + data may fill it."
  else
    _pf_ok "Disk: ${free_gb} GB free on ${target}"
  fi
  return 0
}

# The network-filesystem classification shared by the full storage check and
# the pre-log early_data_dir_guard (#432). Everything listed corrupts or
# crash-loops MySQL/InnoDB (broken POSIX locking, unsafe O_DIRECT/fsync).
_pf_is_network_fstype() {
  case "$1" in
    nfs|nfs3|nfs4|nfsd|cifs|smb|smbfs|smb2|smb3|afpfs|9p|ncpfs|gfs|gfs2|ocfs2|lustre|glusterfs|fuse.glusterfs|ceph|fuse.ceph|beegfs|fuse.sshfs|fuse.s3fs|davfs|fuse.davfs|webdav|fuse.rclone) return 0 ;;
    *) return 1 ;;
  esac
}

# The FOLLOWABLE remedy for a network-filesystem HOST_DATA_DIR (#479). validate_config
# requires the data dir UNDER $HOME (security, Bugbot #384), so "set HOST_DATA_DIR to
# ~/.tracebloc" is un-followable on a network HOME — that path is still NFS. Name the
# options that actually work. Shared by _pf_storage_type and early_data_dir_guard so
# the two remedies can never drift (early_data_dir_guard already had the good text).
_pf_network_fs_remedy() {
  hint "HOST_DATA_DIR must be a LOCAL disk under your \$HOME (paths outside \$HOME are rejected), so on a network home either:"
  hint "  1. install as a user whose home is on a local disk (ask your admin), or"
  hint "  2. set TRACEBLOC_ALLOW_NETWORK_FS=1 to proceed anyway - NOT recommended: the database can corrupt."
  hint "(Datasets may stay on network storage via HOST_DATASET_DIR - only the data dir must be local.)"
}

# Pre-log guard (#432): main() creates HOST_DATA_DIR and tees the session log
# onto it (setup_log_file) BEFORE run_preflight fires — on an NFS home under
# sudo + root_squash that unguarded mkdir fails with a bare error (or the log
# dir lands squashed/nobody-owned) before _pf_storage_type below can print its
# friendly, named failure. Same classification, run first, output only on
# failure. TRACEBLOC_ALLOW_NETWORK_FS defers to the full check's warning.
early_data_dir_guard() {
  local target fstype
  target="${HOST_DATA_DIR:-${HOME:-}/.tracebloc}"
  [[ -n "${TRACEBLOC_ALLOW_NETWORK_FS:-}" ]] && return 0
  # An EXISTING data dir has no at-risk mkdir here, and a healthy machine's
  # re-run must keep reaching the assess hand-off exactly as it did when this
  # check lived only in run_preflight (Bugbot #441). The full preflight guard
  # below still classifies network storage for actual (re)installs.
  [[ -d "$target" ]] && return 0
  fstype="$(_pf_fstype "$target")"
  [[ -z "$fstype" ]] && return 0                 # undetermined — assume local
  _pf_is_network_fstype "$fstype" || return 0
  warn "Storage: ${target} is on a network filesystem (${fstype})."
  hint "The client database (MySQL/InnoDB) corrupts or crash-loops on network storage, and NFS root_squash blocks data-dir setup."
  _pf_network_fs_remedy   # shared followable remedy (#479)
  error "Refusing to create the data directory on ${fstype} before logging starts."
}

# Network-filesystem guard for HOST_DATA_DIR. MySQL/InnoDB corrupts or crash-loops
# on NFS/CIFS/SMB (broken POSIX locking + unsafe O_DIRECT/fsync), and the chart's
# root chown init-container is blocked by NFS root_squash — so a network data dir
# fails ~20 min in with a cryptic CrashLoopBackOff. Catch it in seconds here.
_pf_storage_type() {
  local target fstype disp
  target="${HOST_DATA_DIR:-$HOME/.tracebloc}"
  disp="$target"
  if [[ -n "${HOME:-}" && "$disp" == "$HOME"* ]]; then disp="~${disp#"$HOME"}"; fi
  fstype="$(_pf_fstype "$target")"
  if [[ -z "$fstype" ]]; then
    log "Storage: ${target} — filesystem type undetermined; assuming local."
    success "Local storage (${disp})"
    return 0
  fi
  if _pf_is_network_fstype "$fstype"; then
      if [[ -n "${TRACEBLOC_ALLOW_NETWORK_FS:-}" ]]; then
        warn "Storage: ${target} is on a network filesystem (${fstype}) — proceeding (TRACEBLOC_ALLOW_NETWORK_FS set); the client database may corrupt or crash-loop on network storage."
        return 0
      fi
      _pf_fail_line "Storage: ${target} is on a network filesystem (${fstype}) — the tracebloc client database (MySQL/InnoDB) corrupts or crash-loops on network storage, and NFS root_squash blocks data-dir setup."
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      # The old remedy suggested HOST_DATA_DIR=$HOME/.tracebloc — but on a network HOME
      # that's still NFS, and validate_config rejects paths OUTSIDE $HOME, so it could
      # never work. Use the shared followable remedy (#479).
      _pf_network_fs_remedy
  else
      log "Storage: ${target} (${fstype})"
      success "Local storage (${disp})"
  fi
  # backend#743: datasets MAY live on a network mount (HOST_DATASET_DIR) — only
  # the database dir (HOST_DATA_DIR, checked above) must be local. Note it, never fail.
  if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
    local dfstype; dfstype="$(_pf_fstype "$HOST_DATASET_DIR")"
    info "Dataset dir: ${HOST_DATASET_DIR}${dfstype:+ (${dfstype})} — network mounts are supported here (the database stays on local disk)."
  fi
  return 0
}

_pf_connectivity() {
  # Can't probe without curl — and on the direct ./install-k8s.sh path the
  # installer hasn't installed it yet. Skip with a warning rather than hard-fail
  # with a misleading "egress blocked" (curl is installed downstream).
  if ! has curl; then
    warn "Skipping connectivity check — curl isn't available yet (the installer will add it)."  # style-guard: allow (copy, not a call)
    return 0
  fi
  local backend_host cfail=0 tls_seen=0 c label rest url mode status
  backend_host="$(_pf_backend_host)"

  # Critical: the install cannot succeed without these (image pulls, creds, chart).
  # Entries are "label|url" with an optional third "|strict" field.
  local criticals=(
    "Docker Hub (registry-1.docker.io)|https://registry-1.docker.io/v2/"
    # auth.docker.io is Docker Hub's token endpoint: a network that allows
    # registry-1 but blocks the token host fails only at in-cluster pull time (#416).
    "Docker Hub auth (auth.docker.io)|https://auth.docker.io/token"
    "GitHub Container Registry (ghcr.io)|https://ghcr.io/"
    "tracebloc API (${backend_host})|https://${backend_host}/"
    # The chart repo is probed at its index.yaml, strictly (third field): the site
    # ROOT 404s by design, while the index must exist for `helm repo add` (#385).
    "tracebloc Helm charts (tracebloc.github.io)|https://tracebloc.github.io/client/index.yaml|strict"
  )
  # Tool-binary download hosts — promoted to HARD (#416): a blocked one used to
  # pass preflight then fail the install ~30s later. Only added when the fetch will
  # actually happen (tool absent; a present tool is never re-downloaded). These are
  # UNAMBIGUOUS: the installer always fetches kubectl/k3d/helm from exactly these
  # hosts. Release assets 302 to objects.githubusercontent.com and _pf_probe_url
  # does not follow redirects, so github.com passing proves nothing about the asset
  # host — probe it explicitly. Lockstep with install-k8s.ps1 (drift: check-drift.sh).
  #
  # The Docker-ENGINE install host is deliberately NOT hard: it's path/distro/
  # environment-dependent (Debian→get.docker.com, RHEL clones→download.docker.com,
  # Amazon/Arch/SUSE→distro repos, macOS GUI→desktop.docker.com, headless→Colima via
  # brew/ghcr.io). preflight can't cheaply know which, so hard-probing a fixed host
  # would abort supported paths that never touch it (Bugbot). It goes in `soft`
  # (warn-only) below. On Windows Docker Desktop is the sole path, so install-k8s.ps1
  # keeps desktop.docker.com hard there.
  local soft=()
  if [[ "$OS" == "Linux" ]]; then
    if ! has k3d;     then criticals+=("k3d download (github.com)|https://github.com/" \
                                       "k3d assets (objects.githubusercontent.com)|https://objects.githubusercontent.com/"); fi
    if ! has kubectl; then criticals+=("kubectl (dl.k8s.io)|https://dl.k8s.io/"); fi
    if ! has helm;    then criticals+=("Helm (get.helm.sh)|https://get.helm.sh/"); fi
    if ! has docker;  then soft+=("Docker install (get.docker.com)|https://get.docker.com/" \
                                  "Docker packages (download.docker.com)|https://download.docker.com/"); fi
  elif [[ "$OS" == "Darwin" ]]; then
    # macOS install paths, all keyed on what will actually be fetched (#416):
    #  - Homebrew install (when brew absent): the script from raw.githubusercontent.com,
    #    then a git-clone of Homebrew/brew + core from github.com — both hard.
    #  - kubectl/k3d/helm ALWAYS install via `brew install` -> formula metadata from
    #    formulae.brew.sh (bottles are ghcr.io, probed above; metadata host is separate
    #    and is hit even when brew is already present) -> hard.
    #  - docker is path-dependent: a GUI Mac installs Docker Desktop from
    #    desktop.docker.com (hard — the actual path); a HEADLESS Mac installs
    #    colima/docker via brew, which needs formulae.brew.sh instead. _pf_has_gui_session
    #    (mirrors setup-macos.sh) picks the branch, so each host is probed only on the
    #    path that fetches it — no false-fail on the path that doesn't (Bugbot r3/r4/r5).
    if ! has brew; then criticals+=("Homebrew install (raw.githubusercontent.com)|https://raw.githubusercontent.com/" \
                                    "Homebrew clone (github.com)|https://github.com/"); fi
    local _brew_will_run=""
    if ! has kubectl || ! has k3d || ! has helm; then _brew_will_run=1; fi
    if ! has docker; then
      if _pf_has_gui_session; then
        criticals+=("Docker Desktop (desktop.docker.com)|https://desktop.docker.com/")   # GUI: the actual Docker path
      else
        _brew_will_run=1                                                                  # headless: colima/docker via brew
      fi
    fi
    [[ -n "$_brew_will_run" ]] && criticals+=("Homebrew formulae (formulae.brew.sh)|https://formulae.brew.sh/")
  fi
  # Probe each critical host in the FOREGROUND (so PF_HARD_FAIL updates in THIS
  # shell — a backgrounded spinner subshell couldn't propagate it), advancing a
  # spinner frame before each blocking probe. No sleep: the network probe itself
  # is the delay in production; under test the stubbed probe is instant, so this
  # can never hang. Failures are collected and printed after the line is cleared.
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') fi=0
  local -a fails=()
  tput civis 2>/dev/null || true
  for c in "${criticals[@]}"; do
    label="${c%%|*}"; rest="${c#*|}"; url="${rest%%|*}"
    mode=""; [[ "$rest" == *"|"* ]] && mode="${rest##*|}"
    printf "\r  ${CYAN}%s${RESET} Checking outbound connectivity…" "${frames[fi]}"
    fi=$(( (fi + 1) % ${#frames[@]} ))
    status="$(_pf_probe_url "$url" "$mode")"
    if [[ "$status" != "ok" ]]; then status="$(_pf_probe_url "$url" "$mode")"; fi   # one retry (transient blips)
    if [[ "$status" != "ok" ]]; then
      fails+=("${label}|${status}")
      if [[ "$status" == "tls" ]]; then tls_seen=1; fi
    fi
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true

  if [[ ${#fails[@]} -eq 0 ]]; then
    # Collapsed happy-path line (always shown — this IS the connectivity result,
    # not one of the arch/CPU/RAM/disk lines the summary folds together).
    success "Connected: tracebloc.io, Docker Hub (registry-1.docker.io), GitHub (ghcr.io)"
  else
    local ff
    for ff in "${fails[@]}"; do
      _pf_fail_line "${ff%%|*} unreachable (${ff#*|})"
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      cfail=$(( cfail + 1 ))
    done
  fi

  # Path-dependent Docker-engine hosts: WARN only (never hard) so a blocked host on
  # a path that won't use it doesn't abort a supported install (Bugbot). The
  # ${soft[@]+…} guard keeps `set -u` happy with an empty array on bash 3.2 (macOS).
  for c in ${soft[@]+"${soft[@]}"}; do
    label="${c%%|*}"; url="${c#*|}"
    status="$(_pf_probe_url "$url")"
    [[ "$status" == "ok" ]] || warn "${label} unreachable (${status}) — only needed if the installer fetches Docker from that host; other install paths don't."
  done

  if [[ "$tls_seen" -eq 1 ]]; then
    hint "A TLS/certificate error usually means a break-and-inspect (TLS-inspecting) proxy whose corporate CA isn't trusted here."
    hint "Fix THESE host checks with CURL_CA_BUNDLE=/path/to/corporate-ca.pem (the installer's HTTPS downloads honor it) or by adding the CA to the system trust store. The k3d nodes are trusted separately via TRACEBLOC_CA_BUNDLE (or CURL_CA_BUNDLE) at cluster-create — so CURL_CA_BUNDLE covers both, TRACEBLOC_CA_BUNDLE only the nodes. Ask IT for the bundle if unsure."
  fi
  if [[ "$cfail" -gt 0 ]]; then
    hint "Allow HTTPS (443) egress to the host(s) named above — the always-needed set is registry-1.docker.io, auth.docker.io, ghcr.io, ${backend_host}, tracebloc.github.io, plus any tool-download host listed (dl.k8s.io / get.helm.sh / github.com / objects.githubusercontent.com) — or set HTTP_PROXY if you use a corporate proxy."
  fi
  return 0
}

# One-line hardware summary for the collapsed step-a view:
#   "arch · N CPU cores · N GB memory · N GB free disk"
# Computed from the same readers the individual checks use, so it can never
# disagree with them. Fields that can't be read are simply omitted (arch always
# leads). Printed by run_preflight only when nothing hard-failed — a ✔ summary
# above a ✖ would contradict itself.
_pf_hw_summary_line() {
  local cpu mem_kb mem_gb disk_target disk_kb disk_gb
  local -a parts=("$ARCH")
  cpu="$(_pf_ncpu)"
  if [[ -n "$cpu" ]]; then parts+=("${cpu} CPU cores"); fi
  # Host RAM, not the VM budget (#417): a hardware summary that read "7 GB
  # memory" on a 15 GB machine (Docker up, WSL2/Desktop VM default) was the same
  # flip-flop bug in miniature. Fall back to the runtime only if the host is
  # unreadable, so the field is still populated rather than dropped.
  mem_kb="$(_pf_host_mem_kb)"; [[ -z "$mem_kb" ]] && mem_kb="$(_pf_runtime_mem_kb)"
  if [[ -n "$mem_kb" ]]; then mem_gb=$(( mem_kb / 1024 / 1024 )); parts+=("${mem_gb} GB memory"); fi
  disk_target="$(_pf_docker_root)"
  if [[ ! -d "$disk_target" ]]; then disk_target="/"; fi
  if [[ "$OS" != "Linux" ]]; then disk_target="$HOME"; fi   # Desktop VM disk is opaque; report host
  disk_kb="$(_pf_free_kb "$disk_target")"
  if [[ -n "$disk_kb" ]]; then disk_gb=$(( disk_kb / 1024 / 1024 )); parts+=("${disk_gb} GB free disk"); fi
  local joined="" p
  for p in "${parts[@]}"; do joined="${joined:+$joined · }$p"; done
  success "$joined"
}

# ── Orchestrator ─────────────────────────────────────────────────────────────
run_preflight() {
  if [[ -n "${TRACEBLOC_SKIP_PREFLIGHT:-}" ]]; then
    info "Preflight checks skipped (TRACEBLOC_SKIP_PREFLIGHT set)."
    return 0
  fi
  PF_HARD_FAIL=0
  # Run the arch/CPU/RAM/disk checks in quiet-success mode: on the happy path they
  # print nothing and we collapse them into ONE summary line below; a warning or
  # hard-fail still prints its specific ⚠/✖. '|| true' so a single check returning
  # non-zero can't trip set -e before the others run — PF_HARD_FAIL is the truth.
  PF_QUIET_SUCCESS=1
  _pf_arch         || true
  _pf_cpu          || true
  _pf_memory       || true
  _pf_disk         || true
  # The combined hardware line — only when nothing hard-failed so far.
  if [[ "$PF_HARD_FAIL" -eq 0 ]]; then _pf_hw_summary_line; fi
  # Connectivity (own spinner + combined "Connected:" line) and storage
  # ("Local storage (…)") each print their own always-on summary line.
  _pf_connectivity || true
  _pf_storage_type || true
  unset PF_QUIET_SUCCESS

  if [[ "$PF_HARD_FAIL" -gt 0 ]]; then
    echo ""
    error "Preflight failed — resolve the ✖ item(s) above and re-run. (Override at your own risk with TRACEBLOC_SKIP_PREFLIGHT=1.)"
  fi
}
