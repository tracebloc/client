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
#  backend#1172) and it NEVER mutates. Every probe is read-only and
#  side-effect-free: `/sys` + `/proc` reads, `id`, `command -v`.
#
#  Tiers (see the RFC):
#    0  nothing on the install path asks for root: the macOS node, or a native
#       k3s an administrator prepared for this user.
#    1  off native k3s, the kernel supports unprivileged containers (cgroup v2 +
#       unprivileged userns): setup-linux.sh's rootless tier.
#    2  native k3s otherwise (it runs as root), a kernel that can't run
#       unprivileged containers (old/locked), or an OS this installer does not
#       serve — a one-time admin step is required.
#
#  run_host_probes sets, once:
#    PROBE_PRIVILEGE       root | sudo_nopw | sudo_pw | no_sudo
#    PROBE_CGROUP2         0|1  (Linux only; 0 elsewhere)
#    PROBE_USERNS          0|1  (Linux only; 0 elsewhere)
#    PROBE_SUBID           0|1  (Linux only; subuid+subgid range for this user)
#    PROBE_UIDMAP          0|1  (Linux only; newuidmap+newgidmap present & setuid)
#    INSTALL_TIER          0|1|2
#    INSTALL_TIER_REASON   short machine-readable tag
#
#  Side-effect-safe to source (defaults + function definitions only).
# =============================================================================

# ── Low-level readers (each read-only; overridable in bats) ───────────────────

# _probe_cgroup_v2 — is the host on the unified cgroup v2 hierarchy? Rootless
# containers need it for resource delegation. Read-only existence check.
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

# _probe_wsl — are we running inside a WSL2 distro (Linux inside Windows)? #1179.
# WSL sets WSL_DISTRO_NAME / WSL_INTEROP in the environment and stamps "microsoft"/
# "WSL" into the kernel release. Read-only. Its consumers include the audit note,
# the run contract (refuse_wsl_run, lib/common.sh), which refuses a run in any WSL
# distro but tracebloc's own, and `_kubelet_reservation_platform` (lib/cluster.sh),
# which routes a Linux kernel through this detector so a WSL2 host never gets a
# row measured on a Linux host. Inside WSL2 the environment is still Linux, so the
# Linux install TIERS apply unchanged. Every consumer must source this file — a process
# that lacks it makes the selector answer `unknown`, which the installer and the
# e2e check both refuse. Paths overridable (TRACEBLOC_OSRELEASE_FILE /
# TRACEBLOC_PROC_VERSION_FILE) so it's testable off a real WSL host.
_probe_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  _probe_wsl_kernel
}

# _probe_wsl_kernel — the kernel half of _probe_wsl alone: WSL's kernel stamps
# "microsoft"/"WSL" into its release. An environment variable can be exported
# anywhere; the kernel cannot, so _probe_wsl_ours needs this half.
_probe_wsl_kernel() {
  grep -qiE 'microsoft|wsl' "${TRACEBLOC_OSRELEASE_FILE:-/proc/sys/kernel/osrelease}" 2>/dev/null && return 0
  grep -qiE 'microsoft|wsl' "${TRACEBLOC_PROC_VERSION_FILE:-/proc/version}" 2>/dev/null
}

# TB_WSL_DISTRO — the name of tracebloc's own WSL distro: the one the Windows
# installer imports and runs this core in, `wsl -d tracebloc -u root -- bash …`
# (client-dev#1810 part 1). Inside WSL, native k3s serves this distro only
# (_native_k3s_refuse_host); a user's own distro stays refused.
TB_WSL_DISTRO="tracebloc"

# _probe_wsl_ours — inside WSL, in tracebloc's own distro: a WSL kernel
# (_probe_wsl_kernel, never the environment alone), and WSL_DISTRO_NAME, which
# WSL sets in every process `wsl -d NAME` starts, naming TB_WSL_DISTRO. A Linux
# host that merely exports the name is not WSL, so it is not this distro, and
# keeps every Linux step (client-dev#1810 part 2). Read-only.
_probe_wsl_ours() {
  _probe_wsl_kernel && [[ "${WSL_DISTRO_NAME:-}" == "$TB_WSL_DISTRO" ]]
}

# _probe_windows_drive PATH — does PATH live on a Windows drive that WSL mounts
# into the distro (drvfs)? 0 yes, 1 no (a Linux filesystem: the distro's own ext4,
# or any other Linux-side mount), 2 cannot tell (no mount table, or nothing of
# PATH resolves). Read from the mount table for the mount that holds PATH's
# nearest existing ancestor, symlinks resolved, so a link into /mnt/c is seen.
# drvfs is mounted as `9p` with `aname=drvfs` on WSL2 and as `drvfs` on WSL1, and
# its source is the drive (`C:\`); any one of the three marks it. RFC-0175 D5: a
# volume, the database's InnoDB files among them, never lives on drvfs. The mount
# table is overridable (TRACEBLOC_PROC_MOUNTS_FILE) so it's testable off WSL.
_probe_windows_drive() {
  local p="$1" mounts="${TRACEBLOC_PROC_MOUNTS_FILE:-/proc/self/mounts}" real verdict
  [[ -r "$mounts" ]] || return 2
  [[ "$p" == /* ]] || p="${PWD}/${p}"
  while [[ ! -d "$p" ]]; do
    p="${p%/*}"
    [[ -n "$p" ]] || p=/
  done
  real="$(cd -P "$p" 2>/dev/null && pwd -P)" || return 2
  verdict="$(awk -v path="$real" '
    function unoct(s) {
      gsub(/\\040/, " ", s); gsub(/\\011/, "\t", s); gsub(/\\012/, "\n", s); gsub(/\\134/, "\\", s)
      return s
    }
    NF >= 4 {
      mnt = unoct($2)
      if (mnt != "/" && path != mnt && index(path, mnt "/") != 1) next
      if (length(mnt) < best) next
      best = length(mnt)
      win = ($3 == "drvfs" || $4 ~ /(^|[,;])aname=drvfs([,;]|$)/ || unoct($1) ~ /^[A-Za-z]:/)
      found = 1
    }
    END { if (!found) print "none"; else if (win) print "windows"; else print "linux" }
  ' "$mounts" 2>/dev/null)" || return 2
  case "$verdict" in
    windows) return 0 ;;
    linux)   return 1 ;;
    *)       return 2 ;;
  esac
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
  if tb_root_n true 2>/dev/null; then echo "sudo_nopw"; return 0; fi
  echo "sudo_pw"
}

# _probe_subid_ranges — does THIS user own a subordinate UID/GID range in BOTH
# /etc/subuid and /etc/subgid? Rootless containers map container UIDs into this range
# and need BOTH files — a range in only one is unusable → not present. Entries may
# be keyed by name OR numeric uid, so check both. The files are world-readable; the
# read is side-effect-free. Paths overridable (TRACEBLOC_SUBUID_FILE/TRACEBLOC_SUBGID_FILE) so the
# probe is testable against fixtures. _subid_has_entry lives in common.sh.
_probe_subid_ranges() {
  # Key off the user the containers will actually run as — `id -un`, NOT $USER,
  # which diverges under su/cron, so a re-run can't mis-read a wrong-user entry as
  # satisfied (Asad/Bugbot, client#458).
  local name uid
  name="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  uid="$(id -u 2>/dev/null)"
  _subid_has_entry "${TRACEBLOC_SUBUID_FILE:-/etc/subuid}" "$name" "$uid" \
    && _subid_has_entry "${TRACEBLOC_SUBGID_FILE:-/etc/subgid}" "$name" "$uid"
}

# _probe_uidmap_helpers — are BOTH newuidmap and newgidmap present AND setuid-root?
# Rootless uses them to write the ID mapping; a non-setuid helper is as useless as a
# missing one, so a plain `has` is not enough. `command -v` + a setuid (`-u`) test on
# the resolved path, both side-effect-free.
_probe_uidmap_helpers() {
  # Present AND privileged (setuid bit OR cap_setuid filecaps — see _idmap_helper_ok
  # in common.sh). A setuid-only test wrongly rejects Arch's filecaps `shadow`
  # (Bugbot, client#458).
  _idmap_helper_ok newuidmap && _idmap_helper_ok newgidmap
}

# ── Classification ────────────────────────────────────────────────────────────

# _classify_from_probes — set INSTALL_TIER (+ reason) from the cached PROBE_*
# vars only (no re-probing). Pure, so it is trivially unit-testable: a bats test
# sets the PROBE_* vars and asserts the tier.
_classify_from_probes() {
  INSTALL_TIER=2
  INSTALL_TIER_REASON="unknown"

  # Native k3s runs as root (RFC-0175 D3). install_linux routes k3s before reading
  # the tier; this keeps the panel from promising "zero root" to a run that will ask
  # for sudo. Its one Tier 0 is a host an administrator prepared for this user (1.1g).
  # On a Mac the install serves it is Tier 0: the node runs in Apple's VM from the user's
  # own folder, with no administrator rights (2.1 part 6). A Mac below the floor is refused
  # by the install (refuse_unsupported_mac), so it is never Tier 0 here either.
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]]; then
    local floor="unknown"
    declare -F tb_mac_floor_verdict >/dev/null && floor="$(tb_mac_floor_verdict)"
    if [[ "$floor" != "ok" ]]; then
      INSTALL_TIER=2; INSTALL_TIER_REASON="unsupported-mac"
      return 0
    fi
    INSTALL_TIER=0; INSTALL_TIER_REASON="mac-node"
    return 0
  fi
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Linux" ]]; then
    if [[ "${PROBE_K3S_PREPARED:-0}" == "1" ]]; then
      INSTALL_TIER=0; INSTALL_TIER_REASON="native-k3s-prepared"
      return 0
    fi
    INSTALL_TIER=2; INSTALL_TIER_REASON="native-k3s"
    return 0
  fi

  # Nothing sets PROBE_RUNTIME_USABLE since the runtime probe went; one case in
  # k3s-create.bats, off native k3s, is this arm's one reader.
  # TODO(tracebloc/client-dev#1950): delete the arm with that case.
  if [[ "${PROBE_RUNTIME_USABLE:-0}" == "1" ]]; then
    INSTALL_TIER=0; INSTALL_TIER_REASON="runtime-usable"
    return 0
  fi

  # A Mac never gets here: it is always the macOS node (above, slim client 4.1). Any
  # other non-Linux (e.g. Git Bash / MINGW on Windows) isn't served by this bash
  # installer at all — say so (Bugbot #370).
  if [[ "${OS:-}" != "Linux" ]]; then
    INSTALL_TIER=2; INSTALL_TIER_REASON="unsupported-os"
    return 0
  fi

  # Linux off native k3s: can the kernel run an unprivileged container?
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
  PROBE_PRIVILEGE="$(_probe_privilege)"

  PROBE_CGROUP2=0
  PROBE_USERNS=0
  PROBE_SUBID=0
  PROBE_UIDMAP=0
  PROBE_WSL=0
  # On native k3s: whether an administrator prepared this host for this user, by
  # k3s.sh's one predicate (read with no privileges).
  PROBE_K3S_PREPARED=0
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Linux" && "$(id -u 2>/dev/null)" != "0" ]] \
     && declare -F _native_k3s_prepared_for_me >/dev/null 2>&1 \
     && _native_k3s_prepared_for_me >/dev/null; then
    PROBE_K3S_PREPARED=1
  fi
  if [[ "${OS:-}" == "Linux" ]]; then
    if _probe_cgroup_v2;      then PROBE_CGROUP2=1; fi
    if _probe_userns;         then PROBE_USERNS=1; fi
    if _probe_subid_ranges;   then PROBE_SUBID=1; fi
    if _probe_uidmap_helpers; then PROBE_UIDMAP=1; fi
    if _probe_wsl;            then PROBE_WSL=1; fi
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

  if [[ "${INSTALL_TIER_REASON:-}" == "mac-node" ]]; then
    # The macOS node brings its own runtime.
    _audit_row "Container runtime" "Apple container ${TRACEBLOC_APPLE_CONTAINER_VERSION:-} (set up for you)" note
  fi

  # WSL2 (#1179): inside WSL the environment IS Linux, so the Linux tiers apply.
  if [[ "${PROBE_WSL:-0}" == "1" ]]; then
    _audit_row "Environment" "WSL2 (Linux-in-Windows)" note
  fi

  # The kernel rows are Linux's (a Mac has no such kernel knobs).
  if [[ "${OS:-}" == "Linux" ]]; then
    if [[ "${PROBE_CGROUP2:-0}" == "1" && "${PROBE_USERNS:-0}" == "1" ]]; then
      _audit_row "Kernel" "cgroup v2 + unprivileged userns present" ok
      # Rootless prerequisites (Tier 1): a subuid/subgid range + the setuid uidmap
      # helpers. A missing one is the single narrow admin touch prepare-host
      # remediates (RFC 0001 §2.1) — surface it honestly rather than crash later.
      if [[ "${PROBE_SUBID:-0}" == "1" ]]; then
        _audit_row "Subordinate IDs" "/etc/subuid + /etc/subgid range present" ok
      else
        _audit_row "Subordinate IDs" "no range for this user — one-time admin step" bad
      fi
      if [[ "${PROBE_UIDMAP:-0}" == "1" ]]; then
        _audit_row "uidmap helpers" "newuidmap + newgidmap present (setuid)" ok
      else
        _audit_row "uidmap helpers" "missing or not setuid — one-time admin step" bad
      fi
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
    0)
      case "${INSTALL_TIER_REASON:-}" in
        native-k3s-prepared) echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 0 (zero root) — an administrator prepared native k3s for you; no privileged steps." ;;
        mac-node)            echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 0 (zero root) — the macOS node runs from your own folder on Apple's container runtime; no privileged steps." ;;
        *)                   echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 0 (zero root) — no privileged steps." ;;
      esac
      ;;
    1) echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 1 — set up Docker for your account; a one-time admin step is still needed for now." ;;
    2)
      case "${INSTALL_TIER_REASON:-}" in
        unsupported-os)       echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — this OS isn't supported by this installer directly. On Windows, install with install.ps1, which sets up tracebloc's WSL distro." ;;
        no-cgroup2)           echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — this kernel isn't on cgroup v2; a one-time admin step is needed." ;;
        no-userns)            echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — unprivileged user namespaces are disabled; a one-time admin step is needed." ;;
        native-k3s)           echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — native k3s runs as root; administrator rights are needed once." ;;
        unsupported-mac)      echo -e "  ${TB_HEADING}→ Install tier${RESET}  Tier 2 — tracebloc can't be installed on this Mac. $(declare -F tb_mac_floor_reason >/dev/null && tb_mac_floor_reason "$(tb_mac_floor_verdict)")" ;;
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
