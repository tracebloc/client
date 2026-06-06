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
PF_MIN_CPU="${PF_MIN_CPU:-2}"              # warn below this
PF_REC_CPU="${PF_REC_CPU:-4}"              # recommended (warn) below this

# Non-exiting failure line (common.sh's error() exits; preflight must finish all
# checks first, so failures print here and are recorded in PF_HARD_FAIL). Writes
# to stdout (like warn/success/info) so it stays ordered with the hint() lines
# that follow — only the final aggregated error() writes to stderr.
_pf_fail_line() { echo -e "  ${RED}✖${RESET} $*"; }

# ── Injectable readers (overridden in bats so checks run without net/df) ─────

# Probe a URL for reachability. Echoes one of: ok|dns|refused|timeout|tls|blocked|nocurl
# "Reachable" = any HTTP response (200/401/403 all count — TLS + HTTP completed).
# Respects the caller's HTTP(S)_PROXY env (curl picks it up), so a TLS-inspecting
# proxy without its CA surfaces here as 'tls'.
_pf_probe_url() {
  local url="$1" code ec
  has curl || { echo "nocurl"; return 0; }
  code=$(curl -sS $CURL_SECURE -o /dev/null --max-time 8 -w '%{http_code}' "$url" 2>/dev/null) && ec=0 || ec=$?
  if [[ -n "$code" && "$code" != "000" ]]; then echo "ok"; return 0; fi
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

# Selectors: prefer the runtime view, fall back to the host. The checks (and the
# bats numeric test) call these names; they always emit exactly one integer.
_pf_total_mem_kb() { local v; v="$(_pf_runtime_mem_kb)"; [[ -n "$v" ]] && { echo "$v"; return 0; }; _pf_host_mem_kb; }
_pf_ncpu()         { local v; v="$(_pf_runtime_ncpu)";   [[ -n "$v" ]] && { echo "$v"; return 0; }; _pf_host_ncpu; }

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
    x86_64|amd64) success "Architecture: ${ARCH} (amd64)"; return 0 ;;
  esac
  # Non-amd64 (arm64/aarch64): the tracebloc client images (e.g. mysql-client)
  # are amd64-only, so they need emulation to run.
  if [[ -n "${TRACEBLOC_ALLOW_ARM64:-}" ]]; then
    warn "Architecture: ${ARCH} — proceeding (TRACEBLOC_ALLOW_ARM64 set); amd64-only images may crash if emulation is unavailable."
    return 0
  fi
  if [[ "$OS" != "Linux" ]]; then
    info "Architecture: ${ARCH} — Docker Desktop runs the amd64 client images under emulation (slower, but works)."
    return 0
  fi
  if _pf_amd64_emulation_available; then
    info "Architecture: ${ARCH} — amd64 emulation (QEMU binfmt) available; client images run emulated (slower)."
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
    success "CPU: ${n} cores"
  fi
  return 0
}

_pf_memory() {
  local kb gb mib floor_mib warn_mib src
  kb="$(_pf_total_mem_kb)"
  if [[ -z "$kb" ]]; then warn "Memory: couldn't determine total RAM (skipping)."; return 0; fi
  gb=$(( kb / 1024 / 1024 ))
  mib=$(( kb / 1024 ))
  # Compare in MiB with a 64 MiB grace so a VM that reports e.g. 4 GiB a hair under
  # 4*1024^3 (Colima / Docker Desktop) doesn't floor to 3 GB and false-trip the gate.
  floor_mib=$(( PF_MIN_MEM_GB * 1024 - 64 ))
  warn_mib=$(( PF_WARN_MEM_GB * 1024 ))
  src="host"; [[ -n "$(_pf_runtime_mem_kb)" ]] && src="Docker VM"

  if [[ "$mib" -lt "$floor_mib" ]]; then
    if [[ "$OS" == "Linux" ]]; then
      _pf_fail_line "Memory: only ${gb} GB (${src}) — need ≥ ${PF_MIN_MEM_GB} GB to run the tracebloc client."
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      hint "Resize the VM (or free memory) to ≥ ${PF_WARN_MEM_GB} GB; ${PF_REC_MEM_GB} GB to train locally. Then re-run."
    else
      # Mac/Win: at preflight Docker is usually still down, so this is host RAM —
      # warn (don't block); the create_cluster re-check sees the real VM size.
      warn "Memory: ${gb} GB (${src}) — below the ${PF_MIN_MEM_GB} GB the client needs; it will OOM."
      hint "Docker Desktop → Settings → Resources → Memory: raise to ≥ ${PF_WARN_MEM_GB} GB (${PF_REC_MEM_GB} GB to train), then re-run."
    fi
  elif [[ "$mib" -lt "$warn_mib" ]]; then
    warn "Memory: ${gb} GB (${src}) — enough to run, but training (≈8 GB/job) may OOM; ${PF_REC_MEM_GB} GB recommended to train locally."
    [[ "$OS" != "Linux" ]] && hint "Docker Desktop → Settings → Resources → Memory ≥ ${PF_REC_MEM_GB} GB to train."
  else
    success "Memory: ${gb} GB (${src})"
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
# point `docker info` is reliably up on every OS. WARN-only: the user has already
# waited for Docker to come up, so aborting here would be jarring.
_pf_recheck_runtime_mem() {
  [[ -n "${TRACEBLOC_SKIP_PREFLIGHT:-}" ]] && return 0
  local kb gb; kb="$(_pf_runtime_mem_kb)"
  [[ -z "$kb" ]] && return 0          # daemon still not reporting — nothing to add
  gb=$(( kb / 1024 / 1024 ))
  if [[ $(( kb / 1024 )) -lt $(( PF_WARN_MEM_GB * 1024 )) ]]; then
    warn "Docker is running with ${gb} GB — recommended ≥ ${PF_WARN_MEM_GB} GB (${PF_REC_MEM_GB} GB to train); the client may OOM under load."
    [[ "$OS" != "Linux" ]] && hint "Docker Desktop → Settings → Resources → Memory ≥ ${PF_WARN_MEM_GB} GB, then re-install."
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
    info "Disk: ${free_gb} GB free on ${target} (host) — also ensure Docker Desktop's disk image has ≥ ${PF_WARN_DISK_GB} GB."
    return 0
  fi
  if [[ "$free_gb" -lt "$PF_MIN_DISK_GB" ]]; then
    _pf_fail_line "Disk: only ${free_gb} GB free on ${target} — need ≥ ${PF_MIN_DISK_GB} GB."
    PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
    hint "Free up space or attach a larger disk, then re-run."
  elif [[ "$free_gb" -lt "$PF_WARN_DISK_GB" ]]; then
    warn "Disk: ${free_gb} GB free on ${target} — recommended ≥ ${PF_WARN_DISK_GB} GB; images + data may fill it."
  else
    success "Disk: ${free_gb} GB free on ${target}"
  fi
  return 0
}

_pf_connectivity() {
  info "Checking outbound connectivity to required services..."
  # Can't probe without curl — and on the direct ./install-k8s.sh path the
  # installer hasn't installed it yet. Skip with a warning rather than hard-fail
  # with a misleading "egress blocked" (curl is installed downstream).
  if ! has curl; then
    warn "Skipping connectivity check — curl isn't available yet (the installer will add it)."
    return 0
  fi
  local backend_host cfail=0 tls_seen=0 c label url status
  backend_host="$(_pf_backend_host)"

  # Critical: the install cannot succeed without these (image pulls, creds, chart).
  local criticals=(
    "Docker Hub (registry-1.docker.io)|https://registry-1.docker.io/v2/"
    "GitHub Container Registry (ghcr.io)|https://ghcr.io/"
    "tracebloc API (${backend_host})|https://${backend_host}/"
    "tracebloc Helm charts (tracebloc.github.io)|https://tracebloc.github.io/"
  )
  for c in "${criticals[@]}"; do
    label="${c%%|*}"; url="${c#*|}"
    status="$(_pf_probe_url "$url")"
    if [[ "$status" != "ok" ]]; then status="$(_pf_probe_url "$url")"; fi   # one retry (transient blips)
    if [[ "$status" == "ok" ]]; then
      success "${label} reachable"
    else
      _pf_fail_line "${label} unreachable (${status})"
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      cfail=$(( cfail + 1 ))
      if [[ "$status" == "tls" ]]; then tls_seen=1; fi
    fi
  done

  # Tool-download hosts: only relevant on Linux when the tool isn't present. Warn-only.
  if [[ "$OS" == "Linux" ]]; then
    local conds=()
    if ! has docker;  then conds+=("Docker install (get.docker.com)|https://get.docker.com/"); fi
    if ! has k3d;     then conds+=("k3d install (raw.githubusercontent.com)|https://raw.githubusercontent.com/"); fi
    if ! has kubectl; then conds+=("kubectl (dl.k8s.io)|https://dl.k8s.io/"); fi
    if ! has helm;    then conds+=("Helm (get.helm.sh)|https://get.helm.sh/"); fi
    # ${conds[@]+...} guard: expanding an empty array under `set -u` errors on
    # bash 3.2 (macOS). This expands to nothing when no tools are missing.
    for c in ${conds[@]+"${conds[@]}"}; do
      label="${c%%|*}"; url="${c#*|}"
      status="$(_pf_probe_url "$url")"
      if [[ "$status" == "ok" ]]; then
        success "${label} reachable"
      else
        warn "${label} unreachable (${status}) — needed only to install that tool."
      fi
    done
  fi

  if [[ "$tls_seen" -eq 1 ]]; then
    hint "A TLS/certificate error usually means a break-and-inspect (TLS-inspecting) proxy whose corporate CA isn't trusted here — see the proxy notes."
  fi
  if [[ "$cfail" -gt 0 ]]; then
    hint "Allow HTTPS (443) egress to: registry-1.docker.io, ghcr.io, ${backend_host}, tracebloc.github.io — or set HTTP_PROXY if you use a corporate proxy."
  fi
  return 0
}

# ── Orchestrator ─────────────────────────────────────────────────────────────
run_preflight() {
  if [[ -n "${TRACEBLOC_SKIP_PREFLIGHT:-}" ]]; then
    info "Preflight checks skipped (TRACEBLOC_SKIP_PREFLIGHT set)."
    return 0
  fi
  PF_HARD_FAIL=0
  # '|| true' so a single check returning non-zero can't trip the caller's set -e
  # before the others run — the aggregated counter below is the source of truth.
  _pf_arch         || true
  _pf_cpu          || true
  _pf_memory       || true
  _pf_disk         || true
  _pf_connectivity || true

  if [[ "$PF_HARD_FAIL" -gt 0 ]]; then
    echo ""
    error "Preflight failed — resolve the ✖ item(s) above and re-run. (Override at your own risk with TRACEBLOC_SKIP_PREFLIGHT=1.)"
  fi
}
