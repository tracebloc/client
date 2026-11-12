#!/usr/bin/env bash
# =============================================================================
#  substrate.sh — the substrate: the stamped switch and its token, the
#  substrate refusals, and re-run resolution. Sourced by install-k8s.sh.
# =============================================================================

# ── The installer contract: substrate switch and substrate line ─────────────
#  scripts/spec/install-record.schema.json is the one declaration. The
#  values below are STAMPED from it (the bootstrap ships no spec file), and
#  install-contract.bats holds each one to the schema:
#    TB_SUBSTRATES                  properties.substrate.enum less the substrates
#                                   every key of x-tracebloc-substrate.retired
#                                   retires, space-separated: what a run can select
#    TB_SUBSTRATE_DEFAULT           x-tracebloc-substrate.default
#    TB_SUBSTRATE_FRESH_LINUX       x-tracebloc-substrate.fresh-default.linux
#    TB_SUBSTRATE_RETIRED_LINUX     x-tracebloc-substrate.retired.linux, space-separated
#    TB_SUBSTRATE_RETIRED_MACOS     x-tracebloc-substrate.retired.macos, space-separated
#    TB_SUBSTRATE_RETIRED_WINDOWS   x-tracebloc-substrate.retired.windows, space-separated
#    TB_SUBSTRATE_TOKEN_PREFIX      x-tracebloc-substrate.token-prefix
#    TB_SUBSTRATE_TOKEN_UNSUPPORTED x-tracebloc-substrate.token-unsupported
#  (the install record's stamps are record.sh's)
TB_SUBSTRATES="k3s"
TB_SUBSTRATE_DEFAULT="k3s"
TB_SUBSTRATE_FRESH_LINUX="k3s"
TB_SUBSTRATE_RETIRED_LINUX="k3d"
TB_SUBSTRATE_RETIRED_MACOS="k3d"
TB_SUBSTRATE_RETIRED_WINDOWS="k3d"
TB_SUBSTRATE_TOKEN_PREFIX="tracebloc-installer substrate="
TB_SUBSTRATE_TOKEN_UNSUPPORTED="unsupported"
# The substrate this run was asked for: TRACEBLOC_SUBSTRATE, else the default
# (blank means unset, as for every TRACEBLOC_* setting). There is no flag and no
# alias. main() refines it with tb_substrate_resolve, so a re-run keeps the
# substrate its install recorded, and refuses a value outside the schema's enum
# (tb_substrate_supported) or one retired where it runs, by name, AFTER the
# substrate line has printed. A library caller that never calls the resolver
# keeps this source-time value.
TRACEBLOC_SUBSTRATE_RESOLVED="${TRACEBLOC_SUBSTRATE:-$TB_SUBSTRATE_DEFAULT}"
# Where TRACEBLOC_SUBSTRATE_RESOLVED came from, and what the resolver could not consult, for the
# install log; and a finding it refuses by name after the substrate line.
TB_SUBSTRATE_SOURCE="${TRACEBLOC_SUBSTRATE:+TRACEBLOC_SUBSTRATE}"
TB_SUBSTRATE_NOTE=""
TB_SUBSTRATE_REFUSAL=""
# Why this run moves a machine off a substrate retired where it runs (its record
# names one, tb_substrate_resolve): the line print_substrate_token prints right
# after the substrate line.
TB_SUBSTRATE_MOVED=""
# Set by a refusal just before it exits: install_cleanup then prints no failure
# footer, because a re-run with nothing changed is refused again.
TB_EXIT_REFUSED=""

# tb_substrate_supported -- TRACEBLOC_SUBSTRATE_RESOLVED is a value of the schema's
# enum: one this installer sets up (TB_SUBSTRATES), or one a TB_SUBSTRATE_RETIRED_*
# stamp retires, which the substrate line still names, so that its refusal
# belongs to it (tb_substrate_resolve).
tb_substrate_supported() {
  local s v known="$TB_SUBSTRATES"
  for v in ${!TB_SUBSTRATE_RETIRED_@}; do known+=" ${!v}"; done
  for s in $known; do
    [[ "$s" == "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" ]] && return 0
  done
  return 1
}

# The substrate line: one line, fixed grammar, no colour, so a harness can read it
# from the installer's own output. It names the substrate this run resolved, or
# the "unsupported" sentinel, never the raw request: a free-form value must not
# be able to bend the grammar.
tb_substrate_token() {
  if tb_substrate_supported; then
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TRACEBLOC_SUBSTRATE_RESOLVED"
  else
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TB_SUBSTRATE_TOKEN_UNSUPPORTED"
  fi
}

# Printed by main() before anything that can refuse; setup_log_file copies it
# into the install log once that exists. A person at a terminal does not read it, so
# there it goes to the log only; a pipe, a file or CI gets it on stdout as before.
print_substrate_token() {
  [[ -n "${_TB_STDOUT_TTY:-}" ]] || tb_substrate_token
  TB_SUBSTRATE_TOKEN_PRINTED=1
  if [[ -n "${TB_SUBSTRATE_MOVED:-}" ]]; then info "$TB_SUBSTRATE_MOVED"; fi
}

refuse_unsupported_substrate() {
  tb_substrate_supported && return 0
  TB_EXIT_REFUSED=1
  if [[ "${TB_SUBSTRATE_SOURCE:-TRACEBLOC_SUBSTRATE}" == "TRACEBLOC_SUBSTRATE" ]]; then
    error "TRACEBLOC_SUBSTRATE='${TRACEBLOC_SUBSTRATE_RESOLVED}' is not a runtime this installer can set up (it supports: ${TB_SUBSTRATES// /, }). Unset it to use the default runtime ($(OS=Darwin _tb_substrate_fresh_here) on a Mac, ${TB_SUBSTRATE_FRESH_LINUX} on Linux, inside WSL too)."
  fi
  error "${TB_SUBSTRATE_SOURCE} says this machine runs on '${TRACEBLOC_SUBSTRATE_RESOLVED}', which is not a runtime this installer can set up (it supports: ${TB_SUBSTRATES// /, }). Set TRACEBLOC_SUBSTRATE to the runtime this machine uses, then re-run."
}

# The finding tb_substrate_resolve kept, refused by name: main() calls this right
# after refuse_unsupported_substrate, so the substrate line has printed first.
refuse_unresolved_substrate() {
  [[ -n "${TB_SUBSTRATE_REFUSAL:-}" ]] || return 0
  TB_EXIT_REFUSED=1
  error "$TB_SUBSTRATE_REFUSAL"
}

# ── Re-run resolution (1.1f) ─────────────────────────────────────────────────
# tb_substrate_retired_here SUBSTRATE -- 0 when SUBSTRATE is retired where this
# run is: in this OS's TB_SUBSTRATE_RETIRED_<OS> stamp. Darwin reads _MACOS; Linux
# inside WSL (_probe_wsl, probe.sh) is the Windows installer's distro
# (refuse_wsl_run) and reads _WINDOWS; Linux outside WSL reads _LINUX. 1 when it is
# not, or on any other OS; 2 when this cannot tell: Linux, SUBSTRATE retired on one
# side of WSL's line, and no WSL probe loaded (a stale bootstrap). The one predicate
# every reader of the retirement asks: the resolver, the substrates it offers
# (_tb_substrates_here), the substrate a Mac gets instead (_tb_substrate_fresh_here)
# and cluster.sh's unmeasured-reservation warning. It has one case per stamp this
# build sets, because a TB_ name nothing stamps is read from the user's environment
# (installer-env-canonical.bats). install-contract.bats holds every key of the
# schema's retired map to a stamp this predicate reads, and every stamp to a key.
tb_substrate_retired_here() {
  local s list found=1 os="${OS:-$(uname -s 2>/dev/null)}"
  case "$os" in
    Darwin) list="${TB_SUBSTRATE_RETIRED_MACOS:-}" ;;
    Linux)
      for s in ${TB_SUBSTRATE_RETIRED_LINUX:-} ${TB_SUBSTRATE_RETIRED_WINDOWS:-}; do [[ "$s" == "${1:-}" ]] && found=0; done
      [[ "$found" -eq 0 ]] || return 1
      found=1
      declare -F _probe_wsl >/dev/null 2>&1 || return 2
      if _probe_wsl; then list="${TB_SUBSTRATE_RETIRED_WINDOWS:-}"; else list="${TB_SUBSTRATE_RETIRED_LINUX:-}"; fi ;;
    *) return 1 ;;
  esac
  for s in $list; do [[ "$s" == "${1:-}" ]] && found=0; done
  [[ "$found" -eq 0 ]] || return 1
  return 0
}

# _tb_substrate_fresh_here -- the substrate a machine here gets instead of a
# retired one. On a Mac, the one substrate of TB_SUBSTRATES that retired.macos
# leaves (k3s, in Apple's container runtime); the schema names no fresh default
# for a Mac, because 4.1 leaves it no other. Prints nothing, and fails, when that is not
# exactly one, or on an OS with no case: Linux's is the schema's own
# fresh-default.linux (TB_SUBSTRATE_FRESH_LINUX).
_tb_substrate_fresh_here() {
  local s left=""
  case "${OS:-$(uname -s 2>/dev/null)}" in
    Darwin)
      for s in $TB_SUBSTRATES; do
        tb_substrate_retired_here "$s" && continue
        [[ -z "$left" ]] || return 1
        left="$s"
      done ;;
    *) return 1 ;;
  esac
  [[ -n "$left" ]] || return 1
  printf '%s' "$left"
}

# _tb_substrates_here -- the substrates this installer sets up where this run is,
# comma-separated: TB_SUBSTRATES less those retired here (tb_substrate_retired_here).
# One whose retirement here cannot be told stays listed: a run that asks for it is
# refused by name then. What a refusal that asks for a substrate offers.
_tb_substrates_here() {
  local s out=""
  for s in $TB_SUBSTRATES; do
    if tb_substrate_retired_here "$s"; then continue; fi
    out+="${out:+, }${s}"
  done
  printf '%s' "$out"
}

# _tb_substrate_where -- where this run is, as the retirement's texts name it ("on
# a Mac", "on Linux outside WSL", "inside WSL"). Fails on an OS with no case, and on
# Linux with no WSL probe loaded.
_tb_substrate_where() {
  case "${OS:-$(uname -s 2>/dev/null)}" in
    Darwin) printf '%s' "on a Mac" ;;
    Linux)
      declare -F _probe_wsl >/dev/null 2>&1 || return 1
      if _probe_wsl; then printf '%s' "inside WSL"; else printf '%s' "on Linux outside WSL"; fi ;;
    *) return 1 ;;
  esac
}

# tb_substrate_resolve -- the substrate this run sets up. A machine installed on
# one runtime stays on it without the variable, so the order is:
#   1. TRACEBLOC_SUBSTRATE, when set;
#   2. the substrate in the daily user's install record (tb_record_path);
#   3. on Linux, the root copy, read only as root or through a password-free sudo.
#      Without either it is not consulted and the log says so: a plain user
#      cannot read it by design, so its absence from view is not "cannot tell";
#   4. on Linux, a tracebloc native k3s this user can see without privileges
#      (_native_k3s_live_probe), which catches one whose record is out of reach;
#   5. the default (TB_SUBSTRATE_DEFAULT: native k3s).
# A Mac gets no substrate retired there (TB_SUBSTRATE_RETIRED_MACOS: k3d, slim client
# 4.1), so it has one, the substrate left (_tb_substrate_fresh_here: k3s
# in Apple's container runtime). There TRACEBLOC_SUBSTRATE naming a
# retired one is refused by name, and every other run resolves the Mac's one: a
# record from a k3d install does not keep k3d, and reinstall.sh's refuse_k3d_machine
# refuses such a Mac with the way off k3d (D10); the record's other substrate goes
# in TB_SUBSTRATE_NOTE for the log.
# On Linux a substrate retired where this run is (TB_SUBSTRATE_RETIRED_LINUX outside
# WSL, TB_SUBSTRATE_RETIRED_WINDOWS inside it: k3d, slim client 4.1) is never set up
# there (tb_substrate_retired_here): asked for by the variable, it is refused; named
# by a record, the run resolves the fresh default and TB_SUBSTRATE_MOVED says why,
# and reinstall.sh's refuse_k3d_machine refuses the machine with the way off k3d.
# A record that exists but cannot be read or parsed is "cannot tell", never
# absent: the finding goes in TB_SUBSTRATE_REFUSAL, which main() refuses by name
# after the substrate line, naming the substrates set up here (_tb_substrates_here).
# TRACEBLOC_SUBSTRATE_RESOLVED keeps the requested value, so the line prints it.
# Prints nothing and writes nothing.
tb_substrate_resolve() {
  local rec sub rc=0 dst left
  TB_SUBSTRATE_NOTE=""; TB_SUBSTRATE_REFUSAL=""; TB_SUBSTRATE_MOVED=""
  if [[ -n "${TRACEBLOC_SUBSTRATE:-}" ]]; then
    TRACEBLOC_SUBSTRATE_RESOLVED="$TRACEBLOC_SUBSTRATE"; TB_SUBSTRATE_SOURCE="TRACEBLOC_SUBSTRATE"
    if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Darwin" ]]; then
      if tb_substrate_retired_here "$TRACEBLOC_SUBSTRATE_RESOLVED"; then
        TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, but this installer no longer sets up ${TRACEBLOC_SUBSTRATE_RESOLVED} $(_tb_substrate_where): $(_tb_substrate_where) it sets up $(_tb_substrate_fresh_here) in Apple's container runtime, and no other runtime. Unset TRACEBLOC_SUBSTRATE, then re-run."
      fi
      return 0
    fi
    rc=0; tb_substrate_retired_here "$TRACEBLOC_SUBSTRATE_RESOLVED" || rc=$?
    case "$rc" in
      0)
        # Inside WSL the run is tracebloc's distro or another, which refuse_wsl_run
        # refuses next: either way the way on is the Windows installer.
        if [[ "$(_tb_substrate_where)" == "inside WSL" ]]; then
          TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, which this installer no longer sets up inside WSL: there it sets up native ${TB_SUBSTRATE_FRESH_LINUX}, and only in tracebloc's own distro, which install.ps1 sets up. Install from Windows with install.ps1."
        else
          TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, which this installer no longer sets up $(_tb_substrate_where). Unset TRACEBLOC_SUBSTRATE: it sets up native ${TB_SUBSTRATE_FRESH_LINUX} here."
        fi ;;
      2) TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, and this installer build cannot tell whether it runs inside WSL (probe.sh is missing), so it cannot tell whether ${TRACEBLOC_SUBSTRATE_RESOLVED} is set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash" ;;
    esac
    return 0
  fi
  TRACEBLOC_SUBSTRATE_RESOLVED="$TB_SUBSTRATE_DEFAULT"; TB_SUBSTRATE_SOURCE="the default"
  rec="$(tb_record_path)"
  if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Darwin" ]]; then
    if ! left="$(_tb_substrate_fresh_here)"; then
      TB_SUBSTRATE_REFUSAL="This installer build retires every runtime it supports (${TB_SUBSTRATES// /, }) on a Mac, or none, so it cannot tell which one to set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
      return 0
    fi
    TRACEBLOC_SUBSTRATE_RESOLVED="$left"; TB_SUBSTRATE_SOURCE="the one substrate on a Mac"
    if [[ -e "$rec" ]]; then
      if ! sub="$(_tb_record_substrate_of "$rec")"; then
        TB_SUBSTRATE_NOTE="Substrate: the install record ${rec} exists, but its substrate could not be read from it; $(_tb_substrate_where) this installer sets up ${left} whatever it says."
      elif [[ "$sub" != "$left" ]]; then
        TB_SUBSTRATE_NOTE="Substrate: the install record ${rec} says ${sub}, which this installer no longer sets up $(_tb_substrate_where)."
      fi
    fi
    return 0
  fi
  if [[ -e "$rec" ]]; then
    if sub="$(_tb_record_substrate_of "$rec")"; then
      TRACEBLOC_SUBSTRATE_RESOLVED="$sub"; TB_SUBSTRATE_SOURCE="the install record ${rec}"
      _tb_substrate_move_retired "$sub" "The install record ${rec}"
    else
      TB_SUBSTRATE_REFUSAL="The install record ${rec} exists, but its substrate could not be read from it, so this run cannot tell which runtime this machine was set up on. Set TRACEBLOC_SUBSTRATE to that runtime (it supports: $(_tb_substrates_here)), then re-run."
    fi
    return 0
  fi
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 0
  if dst="$(_tb_record_root_copy_path)" && _tb_record_root_access; then
    if _tb_record_root_run test -e "$dst"; then
      if sub="$(_tb_record_root_run cat "$dst" 2>/dev/null | _tb_record_substrate_in)"; then
        TRACEBLOC_SUBSTRATE_RESOLVED="$sub"; TB_SUBSTRATE_SOURCE="the root copy ${dst}"
        _tb_substrate_move_retired "$sub" "The install record's root copy ${dst}"
      else
        TB_SUBSTRATE_REFUSAL="The install record's root copy ${dst} exists, but its substrate could not be read from it, so this run cannot tell which runtime this machine was set up on. Set TRACEBLOC_SUBSTRATE to that runtime (it supports: $(_tb_substrates_here)), then re-run."
      fi
      return 0
    fi
  else
    TB_SUBSTRATE_NOTE="Substrate: the root copy of the install record was not consulted (this run has neither root nor a password-free sudo)."
  fi
  rc=0; _tb_substrate_k3s_live || rc=$?
  case "$rc" in
    1) ;;
    0) TRACEBLOC_SUBSTRATE_RESOLVED="k3s"; TB_SUBSTRATE_SOURCE="the tracebloc native k3s set up on this machine (systemctl: k3s)" ;;
    *) TB_SUBSTRATE_REFUSAL="tracebloc's native k3s files are on this machine, but systemctl did not answer, so this run cannot tell whether that k3s is set up to run. Check 'systemctl status k3s', or set TRACEBLOC_SUBSTRATE to the runtime this machine uses, then re-run." ;;
  esac
  return 0
}

# _tb_substrate_move_retired SUB WHO -- a record (WHO, as a sentence's subject)
# names SUB: where SUB is retired, the run resolves the fresh default, and
# TB_SUBSTRATE_MOVED says why after the substrate line; reinstall.sh's
# refuse_k3d_machine then refuses it with the way off k3d. Where this cannot tell,
# the run is refused by name. Elsewhere nothing changes.
_tb_substrate_move_retired() {
  local rc=0
  tb_substrate_retired_here "$1" || rc=$?
  case "$rc" in
    0) TRACEBLOC_SUBSTRATE_RESOLVED="$TB_SUBSTRATE_FRESH_LINUX"
       TB_SUBSTRATE_MOVED="${2} says this machine runs on ${1}, which this installer no longer sets up $(_tb_substrate_where)." ;;
    2) TB_SUBSTRATE_REFUSAL="${2} says this machine runs on ${1}, and this installer build cannot tell whether it runs inside WSL (probe.sh is missing), so it cannot tell whether ${1} is still set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash" ;;
  esac
  return 0
}

# _tb_substrate_k3s_live -- _native_k3s_live_probe's answer: 0 when a tracebloc
# native k3s is set up here, 1 when not, 2 when it cannot tell. k3s.sh holds the
# probe; a process that did not source it cannot tell.
_tb_substrate_k3s_live() {
  declare -F _native_k3s_live_probe >/dev/null 2>&1 || return 2
  local rc=0
  _native_k3s_live_probe || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

# _tb_record_substrate_of FILE -- the substrate FILE records. Fails when FILE
# cannot be read, or names no substrate, or more than one.
_tb_record_substrate_of() {
  local text
  text="$(cat "$1" 2>/dev/null)" || return 1
  printf '%s' "$text" | _tb_record_substrate_in
}

# _tb_record_substrate_in -- the substrate in the record text on stdin: the value
# of its one "substrate" key, as a JSON string of [a-z0-9-]. Not tied to the
# writer's layout, so a record another tool rewrote still reads; anything else
# fails, and the value can never bend the substrate line (tb_substrate_token).
_tb_record_substrate_in() {
  local flat n v
  flat="$(tr '\n' ' ')"
  n="$(printf '%s' "$flat" | grep -o '"substrate"' | wc -l | tr -d ' ')"
  [[ "$n" == "1" ]] || return 1
  v="$(printf '%s' "$flat" | sed -n 's/.*"substrate"[[:space:]]*:[[:space:]]*"\([a-z0-9][a-z0-9-]*\)".*/\1/p')"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}
