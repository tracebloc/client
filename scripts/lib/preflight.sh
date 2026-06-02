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
#
#  This file is side-effect-safe to source (defaults + function defs only).
# =============================================================================

# Thresholds (overridable via env — for unusual sites or tests)
PF_MIN_DISK_GB="${PF_MIN_DISK_GB:-5}"      # hard-fail below this (Linux)
PF_WARN_DISK_GB="${PF_WARN_DISK_GB:-20}"   # warn below this
PF_WARN_MEM_GB="${PF_WARN_MEM_GB:-4}"      # warn below this
PF_MIN_CPU="${PF_MIN_CPU:-2}"              # warn below this

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

# Total physical RAM in KB.
_pf_total_mem_kb() {
  if [[ "$OS" == "Darwin" ]]; then
    local b; b=$(sysctl -n hw.memsize 2>/dev/null) || b=""
    [[ -n "$b" ]] && echo $(( b / 1024 ))
  else
    awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null
  fi
}

# Logical CPU count.
_pf_ncpu() {
  if [[ "$OS" == "Darwin" ]]; then
    sysctl -n hw.ncpu 2>/dev/null
  else
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null
  fi
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
  if [[ "$n" -lt "$PF_MIN_CPU" ]]; then
    warn "CPU: ${n} core(s) — recommended ≥ ${PF_MIN_CPU}."
  else
    success "CPU: ${n} cores"
  fi
  return 0
}

_pf_memory() {
  local kb gb; kb="$(_pf_total_mem_kb)"
  if [[ -z "$kb" ]]; then warn "Memory: couldn't determine total RAM (skipping)."; return 0; fi
  gb=$(( kb / 1024 / 1024 ))
  if [[ "$gb" -lt "$PF_WARN_MEM_GB" ]]; then
    warn "Memory: ${gb} GB total — recommended ≥ ${PF_WARN_MEM_GB} GB; k3s + training may run out of memory."
  else
    success "Memory: ${gb} GB"
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
