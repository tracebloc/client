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
  code=$(curl -sS $CURL_SECURE -o /dev/null --max-time 8 -w '%{http_code}' "$url" 2>/dev/null) && ec=0 || ec=$?
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
    x86_64|amd64) _pf_ok "Architecture: ${ARCH} (amd64)"; return 0 ;;
  esac
  # Non-amd64 (arm64/aarch64): the tracebloc client images (e.g. mysql-client)
  # are amd64-only, so they need emulation to run.
  if [[ -n "${TRACEBLOC_ALLOW_ARM64:-}" ]]; then
    warn "Architecture: ${ARCH} — proceeding (TRACEBLOC_ALLOW_ARM64 set); amd64-only images may crash if emulation is unavailable."
    return 0
  fi
  if [[ "$OS" != "Linux" ]]; then
    _pf_note "Architecture: ${ARCH} — Docker Desktop runs the amd64 client images under emulation (slower, but works)."
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
    _pf_ok "Memory: ${gb} GB (${src})"
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
  case "$fstype" in
    nfs|nfs3|nfs4|nfsd|cifs|smb|smbfs|smb2|smb3|afpfs|9p|ncpfs|gfs|gfs2|ocfs2|lustre|glusterfs|fuse.glusterfs|ceph|fuse.ceph|beegfs|fuse.sshfs|fuse.s3fs|davfs|fuse.davfs|webdav|fuse.rclone)
      if [[ -n "${TRACEBLOC_ALLOW_NETWORK_FS:-}" ]]; then
        warn "Storage: ${target} is on a network filesystem (${fstype}) — proceeding (TRACEBLOC_ALLOW_NETWORK_FS set); the client database may corrupt or crash-loop on network storage."
        return 0
      fi
      _pf_fail_line "Storage: ${target} is on a network filesystem (${fstype}) — the tracebloc client database (MySQL/InnoDB) corrupts or crash-loops on network storage, and NFS root_squash blocks data-dir setup."
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      hint "Fix: point HOST_DATA_DIR at a LOCAL disk — the default ~/.tracebloc is local:"
      hint "  HOST_DATA_DIR=\"\$HOME/.tracebloc\" ./install-k8s.sh"
      hint "  (or set TRACEBLOC_ALLOW_NETWORK_FS=1 to proceed anyway — not recommended for the database.)"
      ;;
    *)
      log "Storage: ${target} (${fstype})"
      success "Local storage (${disp})"
      ;;
  esac
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
    warn "Skipping connectivity check — curl isn't available yet (the installer will add it)."
    return 0
  fi
  local backend_host cfail=0 tls_seen=0 c label rest url mode status
  backend_host="$(_pf_backend_host)"

  # Critical: the install cannot succeed without these (image pulls, creds, chart).
  # Entries are "label|url" with an optional third "|strict" field.
  local criticals=(
    "Docker Hub (registry-1.docker.io)|https://registry-1.docker.io/v2/"
    "GitHub Container Registry (ghcr.io)|https://ghcr.io/"
    "tracebloc API (${backend_host})|https://${backend_host}/"
    # The chart repo is probed at its index.yaml, strictly (third field): the site
    # ROOT 404s by design, while the index must exist for `helm repo add` (#385).
    "tracebloc Helm charts (tracebloc.github.io)|https://tracebloc.github.io/client/index.yaml|strict"
  )
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
        _pf_ok "${label} reachable"
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
  mem_kb="$(_pf_total_mem_kb)"
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
