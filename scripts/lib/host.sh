#!/usr/bin/env bash
# =============================================================================
#  host.sh — this host: OS and ARCH, amd64 emulation, the GPU globals, the OS
#  label, the package manager, the run in tracebloc's WSL distro, ssh, and the
#  macOS floor. Sourced by install-k8s.sh.
# =============================================================================

# ── Runtime globals ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
# On macOS, override ARCH with real hardware to avoid Rosetta misdetection
# Capture-then-match: a SIGPIPE'd producer under pipefail reads as "no
# match" here, which would leave an Apple Silicon Mac detected as x86_64 and pick
# the wrong download for every pinned tool.
if [[ "$OS" == "Darwin" ]]; then
  _tb_arm64_flag="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
  [[ "$_tb_arm64_flag" == "1" ]] && ARCH="arm64"
  unset _tb_arm64_flag
fi
[[ "$ARCH" == "x86_64" ]] && ARCH_DL="amd64" || ARCH_DL="arm64"

# True if this machine runs amd64 binaries through QEMU binfmt. Preflight's _pf_arch and
# the engine gate _assert_engine_runs_on_this_arch must give one verdict, so both ask this
# probe and name amd64_emulation_remedy below; a function, so bats can override it.
amd64_emulation_available() { [[ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]]; }

# The command that registers that handler on this Linux machine: the distro's QEMU package
# (binfmt-support registers it on Debian and Ubuntu, systemd-binfmt on Fedora). Native k3s's
# containerd execs through the kernel's own handlers, so the remedy needs no Docker.
amd64_emulation_remedy() {
  if has apt-get; then
    printf 'sudo apt-get install -y qemu-user-static binfmt-support'
  elif has dnf; then
    printf 'sudo dnf install -y qemu-user-static'
  elif has zypper; then
    printf 'sudo zypper install -y qemu-linux-user'
  else
    printf "install your distribution's qemu-user-static package"
  fi
}

# nvidia | amd | apple_silicon | none, or amd_unsupported / nvidia_unsupported for a GPU
# detect_gpu found and left off, because tracebloc has no training image for it (an AMD
# GPU; an NVIDIA GPU on a machine that is not x86_64). Every GPU
# step keys on exactly nvidia or amd, so an _unsupported vendor sets nothing up.
GPU_VENDOR="none"
NVIDIA_DRIVER_OK=false
# detect-gpu.sh's floor verdict for a present NVIDIA driver: ok | below-hard-floor |
# below-compute | unreadable. Empty = not judged (no NVIDIA driver on the host yet).
TB_GPU_FLOOR_VERDICT=""
# Why the GPU was left off as UNSUPPORTED, for the platform: one
# human sentence and the card's name, set by detect-gpu.sh's floor gate on
# below-compute and below-hard-floor, by detect_gpu for a GPU that is not NVIDIA or an
# NVIDIA GPU on a machine that is not x86_64, and
# by the container runtime's GPU probe for an NVIDIA GPU no container can see
# , and in tracebloc's WSL distro by the Windows installer's report of an
# NVIDIA GPU WSL cannot give it (wsl_cannot_see_gpu) -- ONLY those -- and passed to the chart as
# env.GPU_UNSUPPORTED_REASON / env.GPU_UNSUPPORTED_NAME (install-client-helm.sh).
# Empty otherwise: an unreadable host or a failed GPU step is not "unsupported".
# Assigned, never defaulted from the environment.
TB_GPU_UNSUPPORTED_REASON=""
TB_GPU_UNSUPPORTED_NAME=""
# The kind beside the sentence: compute_too_old | driver_too_old |
# not_nvidia | runtime_cannot_see_gpu | arch_unsupported, or, in tracebloc's WSL
# distro, the Windows installer's wsl_cannot_see_gpu; or empty. Passed as
# env.GPU_UNSUPPORTED_CODE.
TB_GPU_UNSUPPORTED_CODE=""
# nvidia-smi's name answer, one line per GPU, for a runtime_cannot_see_gpu report.
TB_GPU_NVIDIA_NAMES=""

# _host_os_label -- this host's operating system as the dashboard shows it
# : "Ubuntu 22.04", "Debian GNU/Linux 12", "macOS 15". Printed
# to stdout, empty when it cannot tell. Passed to the chart as env.TRACEBLOC_HOST_OS
# (install-client-helm.sh _host_os_set_args), and the resource monitor sends it on
# every heartbeat as `os`. Only the installer can answer: the monitor runs in a pod,
# whose /etc/os-release is the image's, and the macOS node's osImage is k3s's.
# os-release is READ, never sourced (it is the host's file, and sourcing it would run
# it); its path and the macOS version take the overrides the setup steps already
# honour (TRACEBLOC_OS_RELEASE_FILE, TRACEBLOC_MACOS_VER).
#
# Inside WSL2 the machine is the Windows host, not the distro: the label is the
# host's ("Windows 11"), from the OS caption the host reports over interop
# (_windows_host_identity_once, install-client-helm.sh). When interop
# cannot answer, or the caption is not one it can read, the distro's label stands.
# Without probe.sh or install-client-helm.sh loaded the distro's label stands too.
_os_release_value() {  # $1 = key, $2 = file: the value, unquoted, or nothing
  sed -n "/^$1=/{s/^$1=//;p;q;}" "$2" 2>/dev/null \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}
# _windows_os_label CAPTION -- "Windows 11", "Windows Server 2022" from a Windows
# OS caption ("Microsoft Windows 11 Pro"), without the vendor and the edition;
# nothing for a caption it cannot read. Case-insensitive. Pure.
_windows_os_label() {
  local re='Windows[[:space:]]+(Server[[:space:]]+[0-9]{4}([[:space:]]+R2)?|[0-9]+)' had_nocase=0 out=""
  shopt -q nocasematch && had_nocase=1
  shopt -s nocasematch
  if [[ "${1:-}" =~ $re ]]; then out="Windows ${BASH_REMATCH[1]}"; fi
  [[ "$had_nocase" == 1 ]] || shopt -u nocasematch
  printf '%s' "$out"
}
_host_os_label() {
  local os name ver major
  os="${OS:-$(uname -s 2>/dev/null)}"
  case "$os" in
    Darwin)
      ver="${TRACEBLOC_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null)}"
      major="${ver%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] || return 0
      # 10.x named its release by the minor (10.15 Catalina); 11 on, by the major.
      if [[ "$major" == 10 ]]; then printf 'macOS %s' "$(cut -d. -f1-2 <<<"$ver")"
      else printf 'macOS %s' "$major"; fi
      ;;
    Linux)
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl \
         && declare -F _windows_host_identity_once >/dev/null 2>&1; then
        local ident="" caption="" label=""
        if ident="$(_windows_host_identity_once)"; then
          IFS='|' read -r _ _ _ _ _ caption <<<"$ident"
          label="$(_windows_os_label "$caption")"
          if [[ -n "$label" ]]; then printf '%s' "$label"; return 0; fi
        fi
      fi
      local f="${TRACEBLOC_OS_RELEASE_FILE:-/etc/os-release}"
      [[ -r "$f" ]] || return 0
      name="$(_os_release_value NAME "$f")"
      ver="$(_os_release_value VERSION_ID "$f")"
      [[ -n "$name" ]] || return 0
      if [[ -n "$ver" ]]; then printf '%s %s' "$name" "$ver"; else printf '%s' "$name"; fi
      ;;
  esac
  return 0
}
# 1 once an NVIDIA GPU is wired into this cluster, else 0. Assigned, never
# defaulted from the environment: only the installer's own GPU steps may set it.
TRACEBLOC_GPU_WIRED=0
PM_INSTALL=""
PM_UPDATE=""

# Installer version shown in the banner's title (" · <version>"). The curl|bash
# bootstrap (install.sh) exports TRACEBLOC_INSTALL_REF — the immutable release tag
# it pinned to, e.g. v1.9.3 — so the title states exactly what is being installed.
# On the direct ./install-k8s.sh path it's unset and the title drops the suffix.
TB_VERSION="${TB_VERSION:-${TRACEBLOC_INSTALL_REF:-}}"

# tb_in_wsl_distro -- this run is inside tracebloc's WSL distro: Linux, and probe.sh's
# _probe_wsl_ours (the WSL kernel, and WSL_DISTRO_NAME is TB_WSL_DISTRO). The one
# predicate the distro's paths read: the run contract below, step d's stdin
# credential (provision.sh) and native k3s's steps (k3s.sh _native_k3s_on_wsl).
# Without probe.sh (a stale bootstrap) nothing is told apart, so nothing is ours.
tb_in_wsl_distro() {
  [[ "${OS:-}" == "Linux" ]] && declare -F _probe_wsl_ours >/dev/null 2>&1 && _probe_wsl_ours
}

# tb_over_ssh -- this run was started from an ssh session: OpenSSH sets
# SSH_CONNECTION on every session and SSH_TTY when it gives it a terminal. Whoever
# runs it is at another machine, not at this one's screen, and may be a script.
tb_over_ssh() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]
}

# ── The Windows installer's two runs ──────
# In tracebloc's WSL distro this core runs twice, and only as the Windows installer
# runs it: `wsl -d tracebloc -u root -- env TRACEBLOC_SUBSTRATE=k3s
# TRACEBLOC_WSL_PHASE=<phase> … bash install-k8s.sh`. The sign-in and `client create`
# are the host CLI's, and create needs the cluster, so:
#   cluster  steps a, b (no CLI), c, then exit 0: the host signs in and creates;
#   client   the credential on stdin (provision_read_stdin_credential), then steps
#            a, b (no CLI), c (finds the cluster), d as that credential, e and f.
# The phase never selects anything: the substrate is named on the line, and the
# phase and the distro's name are refusals (refuse_wsl_run).
TB_WSL_PHASES="cluster client"

# refuse_wsl_run -- the run in tracebloc's WSL distro is the Windows installer's,
# and only its. Refused by name, after the substrate line (main()): in the distro, a
# substrate other than k3s, a phase outside TB_WSL_PHASES, and a client run with no
# credential on stdin (step d would sign in, with no CLI here); in any other WSL
# distro, the run itself, whatever its substrate (a user's own
# distro is no longer served, and native k3s serves tracebloc's distro only),
# told apart by probe.sh's _probe_wsl_kernel and _probe_wsl_ours (a WSL kernel,
# never WSL's environment names alone, which any Linux host can export), so a
# process without probe.sh (a stale bootstrap) refuses nothing here; anywhere else, a
# phase; a stdin credential outside the distro's `client` phase; and what
# provision_read_stdin_credential found wrong with the credential it read
# (TB_STDIN_CRED_REFUSAL). Read-only.
refuse_wsl_run() {
  local ours=0 wsl=0 p ok=0 have="none" why=""
  if tb_in_wsl_distro; then
    ours=1
  elif [[ "${OS:-}" == "Linux" ]] && declare -F _probe_wsl_ours >/dev/null 2>&1 && _probe_wsl_kernel; then
    # probe.sh is loaded and can tell tracebloc's distro from another (its
    # _probe_wsl_ours), and this is a WSL kernel, but not that distro.
    wsl=1
  fi
  if [[ "$ours" -eq 1 ]]; then
    for p in $TB_WSL_PHASES; do
      if [[ "${TRACEBLOC_WSL_PHASE:-}" == "$p" ]]; then ok=1; fi
    done
    [[ -z "${TRACEBLOC_WSL_PHASE:-}" ]] || have="TRACEBLOC_WSL_PHASE='${TRACEBLOC_WSL_PHASE}'"
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then
      why="In tracebloc's WSL distro the installer sets up native k3s only, and this run resolved '${TRACEBLOC_SUBSTRATE_RESOLVED:-}'. Install from Windows with install.ps1, which runs it here."
    elif [[ "$ok" -ne 1 ]]; then
      why="In tracebloc's WSL distro the installer runs as one of the Windows installer's two runs (TRACEBLOC_WSL_PHASE=${TB_WSL_PHASES// / or }), and this run has ${have}. Install from Windows with install.ps1, which runs both."
    elif [[ "${TRACEBLOC_WSL_PHASE}" == "client" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" != 1 ]]; then
      why="In tracebloc's WSL distro the client run takes the credential the Windows installer hands over on stdin (TRACEBLOC_CREDENTIAL_STDIN=1), and this run was handed none. Install from Windows with install.ps1, which hands it over."
    fi
  elif [[ "$wsl" -eq 1 ]]; then
    why="Inside WSL the installer runs only in tracebloc's own distro, '${TB_WSL_DISTRO:-}', which install.ps1 sets up"
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
      why+=", and this is the distro '${WSL_DISTRO_NAME}'"
    fi
    why+=". Install from Windows with install.ps1."
  elif [[ -n "${TRACEBLOC_WSL_PHASE:-}" ]]; then
    why="TRACEBLOC_WSL_PHASE='${TRACEBLOC_WSL_PHASE}' belongs to the Windows installer's runs in tracebloc's WSL distro, and this is not that distro. Unset it, then re-run."
  fi
  if [[ -z "$why" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" == 1 ]] && [[ "$ours" -ne 1 || "${TRACEBLOC_WSL_PHASE:-}" != "client" ]]; then
    why="TRACEBLOC_CREDENTIAL_STDIN=1 belongs to the Windows installer's client run in tracebloc's WSL distro, and this run is not that one. Unset it, then re-run."
  fi
  if [[ -z "$why" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" == 1 ]] && ! declare -F provision_read_stdin_credential >/dev/null 2>&1; then
    why="This installer build can't take a credential on stdin (provision.sh is missing: stale bootstrap). Re-run the installer from Windows."
  fi
  [[ -n "$why" ]] || why="${TB_STDIN_CRED_REFUSAL:-}"
  [[ -n "$why" ]] || return 0
  TB_EXIT_REFUSED=1
  error "$why"
}

# tb_wsl_phase -- this run's phase in tracebloc's WSL distro, or nothing elsewhere.
# Read after refuse_wsl_run, so a phase it prints is one of TB_WSL_PHASES.
tb_wsl_phase() {
  if tb_in_wsl_distro; then printf '%s' "${TRACEBLOC_WSL_PHASE:-}"; fi
}

# tb_wsl_handover_write -- the cluster run's verdict, handed to the Windows installer
# (3.2 part 2c). The host names a file on the cluster run's line,
# TRACEBLOC_WSL_HANDOVER, in a folder only this user can open and the host deletes
# after the install. It reads the file only when the cluster run exits 0, and refuses
# to go on when the file or its line is missing. So main() writes it last, just before
# that exit 0: a file there means this run reached its end. Exactly five lines, which
# replace whatever the file held:
#   INSTALL_STATE_REASON=<word>, the reason the stop-and-check gate set (assess.sh), as
#   it set it -- a tag such as credential-rejected, ns:<namespace> for a healthy
#   client, or empty when the gate did not assess (--force, or a stale bootstrap
#   without assess.sh). On credential-rejected the host runs `client create --reissue`
#   and puts TRACEBLOC_CREDENTIAL_REISSUED=1 on the client run's line;
#   TRACEBLOC_KUBE_CONTEXT=<context>, tracebloc's kube context, which this run's
#   kubeconfig merge added (k3s.sh). The merge leaves the current context alone, so
#   the host names this one to its CLI until the host record does;
#   TRACEBLOC_MACHINE_KIND=, TRACEBLOC_CLOUD_PROVIDER= and TRACEBLOC_HOST_OS=, where
#   this machine runs (provision.sh's _registration_machine_facts, the facts the
#   chart's heartbeat gets in this distro), each empty when it cannot be read. The
#   host runs `client create`, so it puts them in that call's environment, as
#   provision.sh does for its own create, and the registration says where the
#   machine runs before its first heartbeat.
# Only the cluster run writes it, and only to a file the host named. A write that
# fails is an error, so the run never exits 0 without the lines.
tb_wsl_handover_write() {
  [[ "$(tb_wsl_phase 2>/dev/null)" == "cluster" && -n "${TRACEBLOC_WSL_HANDOVER:-}" ]] || return 0
  _TB_REG_MACHINE_KIND=""; _TB_REG_CLOUD_PROVIDER=""; _TB_REG_HOST_OS=""
  if declare -F _registration_machine_facts >/dev/null 2>&1; then _registration_machine_facts; fi
  { printf 'INSTALL_STATE_REASON=%s\nTRACEBLOC_KUBE_CONTEXT=%s\nTRACEBLOC_MACHINE_KIND=%s\nTRACEBLOC_CLOUD_PROVIDER=%s\nTRACEBLOC_HOST_OS=%s\n' \
      "${INSTALL_STATE_REASON:-}" "$(_tb_kube_context)" \
      "${_TB_REG_MACHINE_KIND//[$'\r\n']/}" "${_TB_REG_CLOUD_PROVIDER//[$'\r\n']/}" "${_TB_REG_HOST_OS//[$'\r\n']/}" >"$TRACEBLOC_WSL_HANDOVER"; } 2>/dev/null \
    || error "Couldn't hand what this run found to the Windows installer: ${TRACEBLOC_WSL_HANDOVER} could not be written. Re-run the installer from Windows."
  log "handover: INSTALL_STATE_REASON=${INSTALL_STATE_REASON:-} TRACEBLOC_KUBE_CONTEXT=$(_tb_kube_context) TRACEBLOC_MACHINE_KIND=${_TB_REG_MACHINE_KIND} TRACEBLOC_CLOUD_PROVIDER=${_TB_REG_CLOUD_PROVIDER} TRACEBLOC_HOST_OS=${_TB_REG_HOST_OS} written to ${TRACEBLOC_WSL_HANDOVER}"
}

# tb_wsl_client_state_write -- the client run's TRACEBLOC_CLIENT_STATE, handed to the
# Windows installer, which runs the example use case only on `connected` (as
# setup_example_use_case does). One line, to the file the host named on this run's line.
# A failed write only warns: the host reads a missing file as not connected.
tb_wsl_client_state_write() {
  [[ "$(tb_wsl_phase 2>/dev/null)" == "client" && -n "${TRACEBLOC_WSL_HANDOVER:-}" ]] || return 0
  local state="${TRACEBLOC_CLIENT_STATE:-}"
  state="${state//[$'\r\n']/}"
  { printf 'TRACEBLOC_CLIENT_STATE=%s\n' "$state" >"$TRACEBLOC_WSL_HANDOVER"; } 2>/dev/null \
    || { warn "Couldn't hand the secure environment's state to the Windows installer (${TRACEBLOC_WSL_HANDOVER}); it will not set up the example use case."; return 0; }
  log "handover: TRACEBLOC_CLIENT_STATE=${state} written to ${TRACEBLOC_WSL_HANDOVER}"
}

# ── The macOS floor ───────────────────────────────────────
# Apple silicon with macOS 26 or later (D6, decided 2026-09-29). macOS 26 is the last
# release for Intel Macs, and every M1 or later Mac runs it. This is the floor's one
# declaration, and its words. A Mac below it is stopped by name on every path, before
# anything is written (refuse_unsupported_mac),
# whether or not it already runs tracebloc: one that does keeps the version it runs,
# unsupported, and is not switched off.
TB_MACOS_FLOOR_MAJOR=26

# _tb_macos_version -- this Mac's macOS version, `sw_vers -productVersion`.
# TRACEBLOC_MACOS_VER is the test seam.
_tb_macos_version() { printf '%s' "${TRACEBLOC_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null)}"; }

# tb_mac_floor_verdict -- whether this Mac meets the floor. Prints "ok", "intel",
# "old VERSION", or "unknown [ANSWER]" when sw_vers gave no version; nothing off macOS.
# The processor is ARCH, which the runtime globals above take from `sysctl
# hw.optional.arm64`, never from `uname -m` alone: a shell running under Rosetta on
# Apple silicon is Apple silicon. Intel is named first, because updating macOS cannot
# fix it.
tb_mac_floor_verdict() {
  [[ "${OS:-}" == "Darwin" ]] || return 0
  if [[ "${ARCH:-}" != "arm64" ]]; then
    printf 'intel\n'
    return 0
  fi
  local v major
  v="$(_tb_macos_version)"
  major="${v%%.*}"
  if ! [[ "$major" =~ ^[0-9]+$ ]]; then
    printf 'unknown%s\n' "${v:+ $v}"
    return 0
  fi
  if [ "$major" -lt "$TB_MACOS_FLOOR_MAJOR" ]; then
    printf 'old %s\n' "$v"
    return 0
  fi
  printf 'ok\n'
}

# tb_mac_floor_reason VERDICT -- the words for a verdict below the floor: what this Mac
# is, and what tracebloc needs. They are (a)'s, cli-dev scripts/install.sh. Each caller
# adds only what its own path does next.
tb_mac_floor_reason() {
  local answer
  case "${1:-}" in
    intel)
      printf '%s' "This Mac has an Intel processor (${ARCH:-x86_64}). tracebloc for macOS needs Apple silicon (M1 or later) with macOS ${TB_MACOS_FLOOR_MAJOR} or later." ;;
    old\ *)
      printf '%s' "This Mac runs macOS ${1#old }. tracebloc needs macOS ${TB_MACOS_FLOOR_MAJOR} or later. Update macOS (System Settings > General > Software Update), then run this again." ;;
    unknown|unknown\ *)
      answer="${1#unknown}"
      answer="${answer# }"
      printf '%s' "This installer couldn't read this Mac's macOS version ('sw_vers -productVersion' answered '${answer:-nothing}'), so it can't tell whether this Mac has Apple silicon with macOS ${TB_MACOS_FLOOR_MAJOR} or later." ;;
    *) return 1 ;;
  esac
}

# tb_upgrade_run -- this run is a `tracebloc upgrade`: the CLI's flag,
# TRACEBLOC_UPGRADE_CLI, as install.sh and assess.sh read it. The one rule for
# leaving out the first-install pointer at `tracebloc data ingest`.
tb_upgrade_run() {
  [[ "${TRACEBLOC_UPGRADE_CLI:-0}" == 1 ]]
}

# refuse_unsupported_mac -- a Mac below the floor, stopped by name, on every path.
# main() calls it right after the substrate refusals, so the substrate line has
# printed, and before setup_log_file, so nothing is written yet: no CLI install, no
# repair, no log. The macOS node's refusals (_mac_ct_refuse_host) call it too. One
# message serves a new Mac and an installed one, so nothing probes for an install.
# `tracebloc upgrade` (TRACEBLOC_UPGRADE_CLI) reads any other exit as a failed upgrade
# and sends the user to the installer again, so on that path the same stop exits 0.
refuse_unsupported_mac() {
  local verdict why
  verdict="$(tb_mac_floor_verdict)"
  case "$verdict" in ''|ok) return 0 ;; esac
  why="$(tb_mac_floor_reason "$verdict")"
  why+=" A tracebloc already installed here keeps the version it has, without updates. Nothing was changed on this Mac."
  if [[ "${TRACEBLOC_UPGRADE_CLI:-0}" == 1 ]]; then
    warn "$why"
    _tb_done=1   # an intended exit 0 under install_cleanup (tb_exit_rc)
    exit 0
  fi
  TB_EXIT_REFUSED=1
  case "$verdict" in
    intel)
      tb_fail_head "This Mac has an Intel processor · tracebloc needs Apple silicon"
      tb_fail_next "Nothing was changed on this Mac." "" ;;
    old\ *)
      tb_fail_head "This Mac runs macOS ${verdict#old } · tracebloc needs macOS ${TB_MACOS_FLOOR_MAJOR}"
      tb_fail_next "Update macOS, then run the installer again:" ;;
    *)
      tb_fail_head "This installer couldn't read this Mac's macOS version"
      tb_fail_next "tracebloc needs Apple silicon and macOS ${TB_MACOS_FLOOR_MAJOR} or later.\nNothing was changed on this Mac." "" ;;
  esac
  error_said "" "$why"
}
