#!/usr/bin/env bash
# =============================================================================
#  root.sh — root elevation: the sudo shadow, the root executor (tb_root*) and
#  the sudo preflight. Sourced by install-k8s.sh.
# =============================================================================

# ── Root-aware privileged execution ────────────────────────────
#  The installer's privileged steps are written as `sudo <cmd>`. Two gaps that
#  needlessly excluded real users — a shared-cluster researcher, a root
#  container/VM:
#    (a) when we are ALREADY root, sudo is unnecessary — and often ABSENT on
#        minimal images — so `sudo <cmd>` died with "sudo: command not found"
#        even though <cmd> would have run fine directly; and
#    (b) "sudo isn't installed" was reported as "no sudo access", a different and
#        misleading fix.
#  We shadow `sudo` with a function so every existing `sudo <cmd>` call site is
#  fixed with NO edit: as root, run <cmd> directly (no sudo binary needed);
#  otherwise defer to the real sudo; and when neither is possible, fail the way
#  the real sudo would (non-zero) so best-effort `sudo … || fallback` sites still
#  take their fallback. Only `sudo <command>` forms route through here — the sole
#  option-only uses (`sudo -v` / `sudo -n`) live in preflight_sudo and go through
#  _real_sudo. Detection + the real binary are wrapped in tiny helpers so the
#  bats suite can exercise every branch without a real sudo.
_have_sudo_bin() { type -P sudo >/dev/null 2>&1; }   # real binary, ignoring this fn; no $(...) so a failing probe can't trip set -e on bash <4.4
_real_sudo()     { command sudo "$@"; }           # the real sudo, bypassing the shadow

sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif _have_sudo_bin; then
    _real_sudo "$@"
  else
    # Not root and no sudo binary. Mimic sudo's own not-found failure (non-zero)
    # rather than exit, so best-effort call sites keep working; preflight_sudo
    # aborts up front with an accurate message on the REQUIRED path.
    echo "sudo: not found (you are not root and sudo is not installed)" >&2
    return 127
  fi
}

# ── The root executor ─────────────────────────
#  Every privileged command prepare-host can reach is one call of:
#    tb_root CMD...          as root; may ask for the password (the sudo() shadow);
#    tb_root_n CMD...        as root, never asking (the install record's root copy);
#    tb_root_as USER CMD...  as USER, never asking (the named user's own record).
#  They are the one place `prepare-host --print` lists its plan from, so the plan
#  cannot drift from the run (CLAUDE.md rule 9). --print sets TRACEBLOC_ROOT_PLAN to a
#  file: a command that changes the host is appended to it and NOT run, and a read
#  (_tb_root_reads) runs as this user, never through sudo, so the plan follows
#  what the run would find. Without TRACEBLOC_ROOT_PLAN each runs exactly what the code
#  ran before it: tb_root through the sudo() shadow, the other two with `sudo -n`
#  (or runuser, as root). prepare-host-root-guard.py holds every function
#  prepare-host reaches to this: only the functions exported at the end of this
#  block may name sudo, _real_sudo or runuser.
tb_root()    { _tb_root root "$@"; }
tb_root_n()  { _tb_root root-n "$@"; }
tb_root_as() { local u="$1"; shift; _tb_root "user:${u}" "$@"; }

# tb_root_planning -- 0 under --print. A check of what an earlier step DID (a wait,
# a read-back) has nothing to check while nothing runs, and is skipped on it.
tb_root_planning() { [[ -n "${TRACEBLOC_ROOT_PLAN:-}" ]]; }

# tb_root_bounded SECS CMD... -- CMD as root under _tb_bounded_bg, the pure-bash
# deadline, for a host with no timeout(1). _tb_bounded_bg signals
# the pid it started, so what it backgrounds must be a BINARY, never a function: a
# function runs in a subshell whose death leaves CMD running (measured: install.sh
# ran to its end). So the sudo() shadow's one rule is applied here -- root runs CMD
# bare, anyone else the real sudo binary -- and with neither, tb_root fails at once
# (127) and needs no bound. Under --print CMD is listed like any write, and nothing
# runs. A function of the executor: export -f below.
tb_root_bounded() {
  local secs="$1" real; shift
  if tb_root_planning; then tb_root "$@"; return; fi
  if [ "$(id -u)" -eq 0 ]; then _tb_bounded_bg "$secs" "$@"; return; fi
  real="$(type -P sudo)" || { tb_root "$@"; return; }
  _tb_bounded_bg "$secs" "$real" "$@"
}

_tb_root() {
  local how="$1"; shift
  if [[ -z "${TRACEBLOC_ROOT_PLAN:-}" ]]; then _tb_root_run "$how" "$@"; return; fi
  if _tb_root_reads "$@"; then "$@"; return; fi
  if ! printf '%s\n' "$(_tb_root_line "$how" "$@")" >> "$TRACEBLOC_ROOT_PLAN" 2>/dev/null; then
    # A plan that lost a line is no plan: the --print wrapper refuses to show it.
    : > "${TRACEBLOC_ROOT_PLAN}.broken" 2>/dev/null
    return 1
  fi
  # A body piped to the command (`printf … | tb_root tee FILE`) is read and dropped,
  # so the writer never dies of SIGPIPE. --print runs the plan with stdin from
  # /dev/null, so this never reads the installer itself under `curl | bash`.
  if [ -p /dev/stdin ]; then cat >/dev/null 2>&1 || :; fi
  return 0
}

# _tb_root_run HOW CMD... -- the run itself, one way per HOW.
_tb_root_run() {
  local how="$1" u; shift
  case "$how" in
    root) sudo "$@" ;;
    root-n)
      if [ "$(id -u)" -eq 0 ]; then "$@"; return; fi
      _have_sudo_bin && _real_sudo -n "$@" ;;
    user:*)
      u="${how#user:}"
      if _have_sudo_bin && _real_sudo -n true 2>/dev/null; then _real_sudo -n -u "$u" -- "$@"; return; fi
      if [[ "$(id -u 2>/dev/null)" == "0" ]] && type -P runuser >/dev/null 2>&1; then runuser -u "$u" -- "$@"; return; fi
      return 1 ;;
    *) echo "tb_root: unknown mode '${how}'" >&2; return 2 ;;
  esac
}

# A script run as root that only reads: does PATH ($1) exist? It answers
# present or absent, and nothing when sudo itself failed, which is cannot-tell.
# shellcheck disable=SC2016  # $1 is the inner sh's, on purpose
TRACEBLOC_ROOT_SH_EXISTS='if [ -e "$1" ]; then echo present; else echo absent; fi'

# _tb_root_reads CMD... -- 0 when CMD only reads: the probes prepare-host makes as
# root, which --print makes as this user instead. A closed list: anything else
# changes the host, is listed, and never runs under --print, even as root.
_tb_root_reads() {
  local a
  case "${1:-}" in
    true|test|cat|ls|stat|grep|cmp) return 0 ;;
    # fuser -k kills what holds the file; journalctl can delete or rotate the journal.
    fuser) for a in "$@"; do case "$a" in -*k*) return 1 ;; esac; done; return 0 ;;
    journalctl)
      for a in "$@"; do
        case "$a" in --vacuum-*|--rotate|--flush|--sync|--relinquish-var|--smart-relinquish-var|--setup-keys|--update-catalog) return 1 ;; esac
      done
      return 0 ;;
    find)
      for a in "$@"; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) return 1 ;; esac
      done
      return 0 ;;
    nft) [[ "${2:-}" == list ]] ;;
    iptables|ip6tables) case "${2:-}" in -S|-C|-L|--list|--check|--list-rules) return 0 ;; esac; return 1 ;;
    systemctl)
      shift
      for a in "$@"; do
        case "$a" in
          -*) continue ;;
          is-active|is-enabled|is-failed|status|show|cat) return 0 ;;
          *) return 1 ;;
        esac
      done
      return 1 ;;
    timeout|gtimeout|*/timeout|*/gtimeout) shift; [[ $# -ge 2 ]] && shift && _tb_root_reads "$@" ;;
    env)
      shift
      while [[ $# -gt 0 && ( "$1" == -i || "$1" == *=* ) ]]; do shift; done
      [[ $# -gt 0 ]] && _tb_root_reads "$@" ;;
    # Two fixed scripts read, word for word: the existence check and cluster.sh's
    # leftover scan. Not exported: a `bash -c` child has neither, and no sh is a read there.
    sh)
      [[ "${2:-}" == -c && -n "${3:-}" ]] || return 1
      [[ "$3" == "${TRACEBLOC_ROOT_SH_EXISTS:-}" || "$3" == "${TRACEBLOC_ROOT_SH_LEFTOVER_SCAN:-}" ]] ;;
    k3s|*/k3s) [[ "${2:-}" == kubectl ]] && case "${3:-}" in get|cluster-info|version) return 0 ;; esac; return 1 ;;
    *) return 1 ;;
  esac
}

# _tb_root_line HOW CMD... -- the plan's line for one command: its words, quoted
# for a shell, `as USER: ` before a command run as that user. A scratch path's
# random suffix reads XXXXXX, so the plan and a run name the same file, and a
# proxy URL's credentials read ***.
_tb_root_line() {
  local how="$1" a q out=""; shift
  case "$how" in user:*) out="as ${how#user:}: " ;; esac
  for a in "$@"; do
    a="$(printf '%s' "$a" | sed -E 's#(/tracebloc-[A-Za-z0-9-]*-)[A-Za-z0-9]{6}(/|$)#\1XXXXXX\2#g; s#(://)[^/@[:space:]]+@#\1***@#g')"
    case "$a" in
      '' | *[!A-Za-z0-9_./:=@%+,-]*) q="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
      *) q="$a" ;;
    esac
    out+="${q} "
  done
  printf '%s' "${out% }"
}

# _tb_root_credential cached|prime|keepalive -- the password, for preflight_sudo:
# whether sudo answers without one, asking for it once, and keeping it warm.
_tb_root_credential() {
  case "$1" in
    cached) _real_sudo -n true 2>/dev/null ;;
    prime) _real_sudo -v ;;
    keepalive)
      ( while _real_sudo -n true 2>/dev/null; do sleep 50; done ) &
      SUDO_KEEPALIVE_PID=$! ;;
  esac
}

# Export the shadow (+ its helpers) so `sudo <cmd>` inside `bash -c '…'` subshells
# also routes through it — e.g. the apt-lock wait in setup-linux.sh runs
# `bash -c '… sudo … …'`. Without
# export, those child shells resolve the REAL sudo binary, so a root box without
# sudo installed would still hit "sudo: command not found" there — the exact case
# A2 fixes everywhere else. Harmless to non-bash children, which
# ignore the BASH_FUNC_* environment entries. The executor goes with it, so a
# `bash -c` child plans under --print too. prepare-host-root-guard.py reads this
# line as the executor: only these functions may name sudo.
export -f sudo _real_sudo _have_sudo_bin tb_root tb_root_n tb_root_as tb_root_planning tb_root_bounded _tb_root _tb_root_run _tb_root_reads _tb_root_line _tb_root_credential

# ── Sudo preflight — warm the credential cache before spinners hide prompts ──
#  Call once at the start of install_macos / install_linux. Establishes that the
#  privileged steps below can run, and (when a password is needed) primes the
#  sudo credential once so later steps behind spinners don't re-prompt.
# preflight_sudo [PURPOSE [REMEDY]] -- PURPOSE finishes "tracebloc needs your password
# once to ...": by default, setting up native k3s and the system tools it needs.
# REMEDY is what the machine line of a refusal (no sudo, or a failed password) says
# to do.
preflight_sudo() {
  # --print runs nothing as root, so it asks for no password.
  if tb_root_planning; then
    return 0
  fi
  # Already root — nothing to prime; the sudo() shadow runs privileged steps
  # directly and needs no sudo binary. Fixes root containers/VMs and minimal
  # images without sudo (A2).
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  # Not root AND no sudo binary — the honest, actionable failure (previously
  # conflated with "no sudo access"). The caller's REMEDY joins the machine line:
  # native k3s's names prepare-host, the way forward for a user who cannot sudo.
  if ! _have_sudo_bin; then
    [[ -n "$_TB_FAIL_FIRM" ]] || tb_fail_next "Install sudo, or run the installer as root:"
    error_said "sudo isn't installed on this machine" "This machine needs administrator rights to install k3s and system tools, but you are not root and sudo isn't installed. Re-run as root, or install sudo (e.g. apt-get install sudo) and try again.${2:+ $2}"
  fi
  # Sudo present and already usable without a password (cached / NOPASSWD).
  if _tb_root_credential cached; then
    return 0
  fi
  # Prompt once, then keep the credential warm. One line, then the system's own
  # "Password:" prompt.
  hint "tracebloc needs your password once to ${1:-install system tools}."
  echo ""
  if ! _tb_root_credential prime; then
    # The caller may have said what to do already (tb_fail_next), as native k3s does.
    [[ -n "$_TB_FAIL_SET" ]] || tb_fail_next "Run the installer again as a user who can use sudo:"
    error_said "Couldn't get administrator rights" "Could not obtain administrator privileges (sudo authentication failed). ${2:-Re-run as a user allowed to sudo, or as root.}"
  fi
  echo ""
  _tb_root_credential keepalive
}
