#!/usr/bin/env bash
# =============================================================================
#  probe.sh — least-privilege install: host CAPABILITY + PRIVILEGE detection.
#
#  RFC 0001 (least-privilege install). This module answers ONE question, read-
#  only and never-fatal: "what is the LOWEST-privilege tier that can install
#  tracebloc on THIS host?" — so the installer can stop demanding sudo up front.
#
#  It is the sensing + reporting layer ONLY. It classifies the host and renders
#  an audit; it does NOT branch the install (that is the tier-routing step,
#  backend#1172) and it NEVER mutates. Every default probe is read-only and
#  side-effect-free: `docker info` (no image pull), `/sys` + `/proc` reads,
#  `id`, `command -v`. The one probe that could touch the network/daemon (a
#  `hello-world` pull) is gated behind --verify (TB_PROBE_VERIFY=1) and is NEVER
#  on the default path.
#
#  Tiers (see the RFC):
#    0  a container is already runnable AS THIS USER (`docker info` OK) — zero root.
#    1  no usable runtime, but the kernel supports unprivileged containers
#       (cgroup v2 + unprivileged userns) — set up rootless Docker, still no root.
#    2  the kernel can't run unprivileged containers (old/locked), or (non-Linux)
#       the runtime isn't up — a one-time admin step is required.
#
#  run_host_probes sets, once:
#    PROBE_RUNTIME_USABLE  0|1
#    PROBE_PRIVILEGE       root | sudo_nopw | sudo_pw | no_sudo
#    PROBE_CGROUP2         0|1  (Linux only; 0 elsewhere)
#    PROBE_USERNS          0|1  (Linux only; 0 elsewhere)
#    INSTALL_TIER          0|1|2
#    INSTALL_TIER_REASON   short machine-readable tag
#
#  Side-effect-safe to source (defaults + function definitions only).
# =============================================================================

# Opt-in only: prove the runtime end-to-end by actually running a throwaway
# container. It PULLS an image, so it must never run on the default path — the
# default `docker info` check already proves binary + daemon + our socket
# permission without touching the network.
: "${TB_PROBE_VERIFY:=0}"

# ── Low-level readers (each read-only; overridable in bats) ───────────────────

# _probe_runtime_usable — is a container runtime usable AS THIS USER, right now?
# `docker info` exit 0 proves, in one call: the binary exists, the daemon is
# reachable, AND this user can talk to the socket (docker-group membership or a
# running rootless daemon). That is exactly the Tier-0 condition. No image pull.
_probe_runtime_usable() {
  has docker || return 1
  docker info >/dev/null 2>&1
}

# _probe_verify_runtime — opt-in (--verify / TB_PROBE_VERIFY=1): actually run a
# container end-to-end. PULLS an image, so it is never on the default path. When
# the flag is off this is a no-op that returns success (nothing to disprove).
_probe_verify_runtime() {
  [[ "${TB_PROBE_VERIFY:-0}" == 1 ]] || return 0
  has docker || return 1
  docker run --rm hello-world >/dev/null 2>&1
}

# _probe_cgroup_v2 — is the host on the unified cgroup v2 hierarchy? Rootless
# Docker needs it for resource delegation. Read-only existence check.
_probe_cgroup_v2() {
  [[ -e /sys/fs/cgroup/cgroup.controllers ]]
}

# _probe_userns — are unprivileged user namespaces available? Rootless containers
# need them. Two read-only signals:
#   * /proc/sys/user/max_user_namespaces > 0  (present on all modern kernels), and
#   * kernel.unprivileged_userns_clone == 1    (Debian/Ubuntu-specific gate — must
#     be 1 WHERE PRESENT; if the file is absent the kernel doesn't gate on it, so
#     its absence alone is not a failure).
_probe_userns() {
  local max clone
  max="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)"
  [[ "$max" =~ ^[0-9]+$ ]] && [[ "$max" -gt 0 ]] || return 1
  if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
    clone="$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)"
    [[ "$clone" == 1 ]] || return 1
  fi
  return 0
}

# _probe_privilege — echo this shell's privilege posture (for honest messaging,
# backlog A2). Distinguishes the four cases the installer must treat differently:
#   root       already uid 0 — no sudo needed at all
#   sudo_nopw  not root; sudo works without a password (cached or NOPASSWD)
#   sudo_pw    not root; sudo is present but will prompt for a password
#   no_sudo    not root; sudo is not installed / not usable
# `id -u`, `command -v sudo`, and `sudo -n true` are all side-effect-free.
_probe_privilege() {
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then echo "root"; return 0; fi
  # Detect the real sudo *binary*, never a `sudo` shell function common.sh
  # installs (the A2 shadow). `has sudo` / a bare `sudo -n true` both resolve
  # to that function, so a host with no sudo at all would look like sudo is
  # present and we'd misreport the posture as sudo_pw instead of no_sudo
  # (Bugbot #372). Reuse the same primitives preflight_sudo uses: _have_sudo_bin
  # (type -P, ignores functions) and _real_sudo (command sudo, bypasses it).
  if ! _have_sudo_bin; then echo "no_sudo"; return 0; fi
  if _real_sudo -n true 2>/dev/null; then echo "sudo_nopw"; return 0; fi
  echo "sudo_pw"
}

# ── Classification ────────────────────────────────────────────────────────────

# _classify_from_probes — set INSTALL_TIER (+ reason) from the cached PROBE_*
# vars only (no re-probing). Pure, so it is trivially unit-testable: a bats test
# sets the PROBE_* vars and asserts the tier. Order matters — a usable runtime
# always wins (Tier 0), regardless of kernel/privilege.
_classify_from_probes() {
  INSTALL_TIER=2
  INSTALL_TIER_REASON="unknown"

  if [[ "${PROBE_RUNTIME_USABLE:-0}" == "1" ]]; then
    INSTALL_TIER=0; INSTALL_TIER_REASON="runtime-usable"
    return 0
  fi

  # No usable runtime. On macOS the runtime is Docker Desktop (a privileged GUI
  # install) → Tier 2 with a Docker-Desktop remedy. Any OTHER non-Linux (e.g. Git
  # Bash / MINGW on Windows) isn't served by this bash installer at all — say so
  # rather than misdirect to Docker Desktop (Bugbot #370).
  if [[ "${OS:-}" == "Darwin" ]]; then
    INSTALL_TIER=2; INSTALL_TIER_REASON="needs-docker-desktop"
    return 0
  fi
  if [[ "${OS:-}" != "Linux" ]]; then
    INSTALL_TIER=2; INSTALL_TIER_REASON="unsupported-os"
    return 0
  fi

  # Linux, no runtime: can the kernel run an unprivileged container?
  if [[ "${PROBE_CGROUP2:-0}" != "1" ]]; then
    INSTALL_TIER=2; INSTALL_TIER_REASON="no-cgroup2"
    return 0
  fi
  if [[ "${PROBE_USERNS:-0}" != "1" ]]; then
    INSTALL_TIER=2; INSTALL_TIER_REASON="no-userns"
    return 0
  fi
  INSTALL_TIER=1; INSTALL_TIER_REASON="rootless-capable"
  return 0
}

# run_host_probes — run every probe ONCE, cache the results in PROBE_* module
# vars, and classify the tier. Read-only, never-fatal. Uses explicit `if`
# assignments (not `probe && VAR=1`) so a failing probe can't trip `set -e`.
run_host_probes() {
  PROBE_RUNTIME_USABLE=0
  if _probe_runtime_usable; then
    PROBE_RUNTIME_USABLE=1
    # --verify (opt-in, TB_PROBE_VERIFY=1): confirm end-to-end by actually running
    # a throwaway container. A daemon that answers `docker info` but can't run a
    # container (broken storage driver, etc.) is then correctly NOT usable. Off by
    # default — this is the ONLY probe that pulls an image.
    if [[ "${TB_PROBE_VERIFY:-0}" == "1" ]] && ! _probe_verify_runtime; then
      PROBE_RUNTIME_USABLE=0
    fi
  fi

  PROBE_PRIVILEGE="$(_probe_privilege)"

  PROBE_CGROUP2=0
  PROBE_USERNS=0
  if [[ "${OS:-}" == "Linux" ]]; then
    if _probe_cgroup_v2; then PROBE_CGROUP2=1; fi
    if _probe_userns;   then PROBE_USERNS=1; fi
  fi

  _classify_from_probes
  return 0
}

# ── Audit report ──────────────────────────────────────────────────────────────

# _audit_row LABEL VALUE MARK — one aligned row. MARK is ok|bad|note. LABEL and
# VALUE are plain text (padded); the coloured mark is last so the escape codes
# never throw off column alignment.
_audit_row() {
  local label="$1" value="$2" mark="$3" m
  case "$mark" in
    ok)  m="${GREEN}✓${RESET}" ;;
    bad) m="${RED}✗${RESET}" ;;
    *)   m="${DIM}–${RESET}" ;;
  esac
  printf '  %-18s %-46s %b\n' "$label" "$value" "$m"
}

# render_host_audit — print the "Host check" panel from the cached PROBE_* vars.
# Call run_host_probes first (host_audit does both). Read-only; prints only.
render_host_audit() {
  echo ""
  echo -e "  ${BOLD}Host check${RESET}"

  if [[ "${PROBE_RUNTIME_USABLE:-0}" == "1" ]]; then
    local ver; ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    _audit_row "Container runtime" "Docker ${ver:-(running)} — docker info OK" ok
  else
    _audit_row "Container runtime" "none usable as this user" note
  fi

  # Kernel row is only meaningful on Linux when there is no usable runtime yet
  # (Tier 0 doesn't care about the modules; a Mac has no such kernel knobs).
  if [[ "${OS:-}" == "Linux" && "${PROBE_RUNTIME_USABLE:-0}" != "1" ]]; then
    if [[ "${PROBE_CGROUP2:-0}" == "1" && "${PROBE_USERNS:-0}" == "1" ]]; then
      _audit_row "Kernel" "cgroup v2 + unprivileged userns present" ok
    elif [[ "${PROBE_CGROUP2:-0}" != "1" ]]; then
      _audit_row "Kernel" "cgroup v2 not enabled" bad
    else
      _audit_row "Kernel" "unprivileged userns disabled" bad
    fi
  fi

  case "${PROBE_PRIVILEGE:-}" in
    root)      _audit_row "Privilege" "running as root" note ;;
    sudo_nopw) _audit_row "Privilege" "regular user; passwordless sudo" note ;;
    sudo_pw)   _audit_row "Privilege" "regular user; sudo needs a password" note ;;
    no_sudo)   _audit_row "Privilege" "regular user; no sudo" note ;;
  esac

  case "${INSTALL_TIER:-2}" in
    0) echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 0 (zero root) — a container is already runnable; no privileged steps." ;;
    1) echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 1 — set up rootless Docker in your account (no admin needed)." ;;
    2)
      case "${INSTALL_TIER_REASON:-}" in
        needs-docker-desktop) echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — Docker isn't running; start/install Docker Desktop (needs admin once)." ;;
        unsupported-os)       echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — this OS isn't supported by this installer; on Windows use the PowerShell installer (install.ps1)." ;;
        no-cgroup2)           echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — this kernel isn't on cgroup v2; a one-time admin step is needed." ;;
        no-userns)            echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — unprivileged user namespaces are disabled; a one-time admin step is needed." ;;
        *)                    echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — a one-time admin step is needed to prepare this host." ;;
      esac
      ;;
  esac
}

# host_audit — the public entry: probe, then render. Read-only, never-fatal.
host_audit() {
  run_host_probes
  render_host_audit
}
