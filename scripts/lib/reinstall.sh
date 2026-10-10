#!/usr/bin/env bash
# =============================================================================
#  reinstall.sh — a k3d machine moves to native k3s only through the offboard,
#  and native k3s is never set up beside a live k3d (RFC-0175 D10).
#
#  A k3d machine is reinstalled, not migrated: the installer detects it
#  read-only, says what the move means, and refuses unless the user consents.
#  The consented offboard is behind the release switch (TB_K3D_REINSTALL, stamped
#  in common.sh from the schema's x-tracebloc-reinstall block), which ships at
#  `offboard`. Under `refuse` the consent variable is never read and no terminal
#  is asked, so nothing in the environment can reach an offboard.
#
#  main() calls refuse_k3s_beside_live_k3d right after the substrate refusals,
#  before the prepare-host dispatch and before validate_config, so nothing is
#  installed, written or started before it answers. A consented offboard runs
#  later, in reinstall_offboard_k3d: after step a's refusals, before step b.
# =============================================================================

# ── Detection ────────────────────────────────────────────────────────────────

# _reinstall_detect -- what k3d this machine holds, read-only. Each step takes its
# answer from a producer that already exists, and nothing here prompts, writes or
# starts anything. Sets:
#   TB_REINSTALL_FOUND   none | tracebloc | other | cannot-tell
#   TB_REINSTALL_CLUSTER tracebloc's k3d cluster, when one was found
#   TB_REINSTALL_OTHERS  every other k3d cluster found, space-separated
#   TB_REINSTALL_PROBE   for cannot-tell: what could not answer
#   TB_REINSTALL_HOW     ...how it failed: "did not answer", or what it said
#   TB_REINSTALL_REMEDY  ...and how to make it answer
# The steps:
#   1. the install record (tb_record_path): its substrate and its cluster_name.
#      No record is the common case (most k3d machines predate the record).
#   2. `has k3d` / `has docker`, checked first: with neither, no k3d cluster can run
#      here and the answer is none, with nothing read and no probe run (assess.sh's
#      own fresh-host rule). An unreadable record only matters once one can.
#   3. The cluster to look for: the record's, else CLUSTER_NAME, held to
#      validate_config's name rule first, because this runs before validate_config
#      does: a recorded name that breaks it is cannot tell, and a CLUSTER_NAME that
#      breaks it is refused in validate_config's own words
#      (_refuse_invalid_cluster_name).
#   4. _k3d_live_clusters, first: every cluster k3d lists. A listing that timed out
#      is "start Docker"; one that failed fast quotes what k3d said, because a
#      permission error on the Docker socket is not fixed by starting Docker
#      (client-dev#1606). A listing that answered is the answer: the cluster from
#      step 3 is there when it is listed, and every other listed cluster is
#      another's. No second read decides it, because a read that failed after this
#      one completed would overrule a definite answer with "cannot tell"
#      (client-dev#1719).
#   5. with docker: _docker_answers, then the k3d-labelled containers, stopped ones
#      included, merged into what k3d listed. Docker not answering, or refusing this
#      user, is cannot tell only when k3d gave no answer of its own; after a k3d
#      listing that answered it is an info line, and the listing decides.
# One exception (1.1g), for a user adopting a host an administrator prepared for them
# who cannot reach Docker at all (_reinstall_adopt_blind). k3d clusters are the
# machine's Docker containers, prepare-host looked for them as the administrator
# before it set k3s up, and this user cannot have started one since. So for them a
# k3d listing that fails fast, and a Docker that does not answer them, go on with an
# info line instead of cannot tell. A listed cluster, a listing that did not answer,
# and anything Docker does answer are read as everywhere.
_reinstall_detect() {
  TB_REINSTALL_FOUND="none"; TB_REINSTALL_CLUSTER=""; TB_REINSTALL_OTHERS=""
  TB_REINSTALL_PROBE=""; TB_REINSTALL_HOW=""; TB_REINSTALL_REMEDY=""; _TB_REINSTALL_BLIND_SAID=""
  local name="" rec_rc=0 has_k3d=0 has_docker=0 rc list n ps what how errf tracebloc=0 blind=0 listed=0
  has k3d && has_k3d=1
  has docker && has_docker=1
  (( has_k3d || has_docker )) || return 0
  _reinstall_adopt_blind && blind=1

  name="$(_reinstall_record_cluster)" || rec_rc=$?

  if [[ "$rec_rc" -ne 0 && "$rec_rc" -ne 1 ]]; then
    _reinstall_cannot_tell "the install record $(tb_record_path)" \
      "Check it is the file this installer wrote, or move it aside, then re-run."
    return 0
  fi
  # A recorded name was held to the rule by _reinstall_record_cluster (rc 2 above),
  # so a name that breaks it here is CLUSTER_NAME's: a setting validate_config would
  # refuse, refused now in its words, before any probe sees it.
  name="${name:-${CLUSTER_NAME:-}}"
  _refuse_invalid_cluster_name "$name"

  if (( has_k3d )); then
    # The listing first: it alone tells a k3d that did not answer (start Docker) from
    # one that failed fast (quote it, client-dev#1606), and a fast failure is where
    # _reinstall_adopt_blind's exception applies. Once k3d has answered, its listing
    # alone decides tracebloc's own cluster (client-dev#1719).
    local lrc=0
    list="$(_k3d_live_clusters)" || lrc=$?
    case "$lrc" in
      0|1) ;;
      3) if (( blind )); then
           _reinstall_blind_go_on "k3d is installed but cannot list clusters as you (${list%%$'\n'*})"
         else
           _reinstall_cannot_tell "the k3d cluster listing ('k3d cluster list')" \
             "Fix what k3d reports (start Docker if it is not running), then re-run." "failed (${list})"
           return 0
         fi ;;
      *) _reinstall_cannot_tell "the k3d cluster listing ('k3d cluster list')" \
           "Start Docker so k3d can answer, then re-run."
         return 0 ;;
    esac
    [[ "$lrc" -gt 1 ]] || listed=1
    # Only a listing that answered 0 lists clusters; 1 is none, whatever it printed.
    if [[ "$lrc" -eq 0 ]]; then
      while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ "$n" == "$name" ]]; then tracebloc=1; else _reinstall_add_other "$n"; fi
      done <<<"$list"
    fi
  fi

  if (( has_docker )) && (( blind )) && ! _docker_answers; then
    _reinstall_blind_go_on "Docker ('docker info') does not answer you"
  elif (( has_docker )); then
    # A Docker that does not answer after k3d's listing did never overrules it: the
    # listing is a read that completed (client-dev#1719).
    # Each read keeps its status and its stderr: 124 is the deadline (Docker did not
    # answer), anything else failed fast and is quoted -- "start Docker" is the wrong
    # remedy for a permission error on a running daemon (client-dev#1748, the k3d
    # arm's split above, client-dev#1606).
    rc=0; ps=""
    errf="$(mktemp "${TMPDIR:-/tmp}/tracebloc-docker-read-XXXXXX" 2>/dev/null)" || errf=/dev/null
    _docker_answers "$errf" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      what="Docker ('docker info')"
    else
      ps="$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps -a --filter label=app=k3d --format '{{.Label "k3d.cluster"}}' 2>"$errf")" || rc=$?
      what="Docker's container list ('docker ps')"
    fi
    how="$(_reinstall_read_how "$rc" "$errf")"
    [[ "$errf" == /dev/null ]] || rm -f "$errf"
    if [[ "$rc" -ne 0 ]] && (( listed )); then
      info "${what} ${how}; k3d's own cluster listing did, and it decides."
      ps=""   # what a failed read printed before it failed is no answer either (client-dev#1731)
    elif [[ "$rc" -eq 124 ]]; then
      _reinstall_cannot_tell "$what" \
        "Start Docker, or run as a user Docker answers, then re-run."
      return 0
    elif [[ "$rc" -ne 0 ]]; then
      _reinstall_cannot_tell "$what" \
        "Fix what Docker reports (start Docker if it is not running, or run as a user Docker answers), then re-run." "$how"
      return 0
    fi
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      if [[ "$n" == "$name" ]]; then tracebloc=1; else _reinstall_add_other "$n"; fi
    done <<<"$ps"
  fi

  if [[ -n "$TB_REINSTALL_OTHERS" ]]; then TB_REINSTALL_FOUND="other"
  elif (( tracebloc )); then TB_REINSTALL_FOUND="tracebloc"
  fi
  (( tracebloc )) && TB_REINSTALL_CLUSTER="$name"
  return 0
}

# _reinstall_adopt_blind -- 0 when this run adopts a host an administrator prepared
# for this user (not root, _native_k3s_prepared_for_me) and this user cannot reach
# Docker at all (_native_k3s_docker_unreachable). Both live in k3s.sh; without them
# (a stale bootstrap) this is 1, and the probes are read as everywhere.
_reinstall_adopt_blind() {
  [[ "$(id -u 2>/dev/null)" != "0" ]] || return 1
  declare -F _native_k3s_prepared_for_me >/dev/null 2>&1 || return 1
  declare -F _native_k3s_docker_unreachable >/dev/null 2>&1 || return 1
  _native_k3s_prepared_for_me >/dev/null || return 1
  _native_k3s_docker_unreachable
}

# _reinstall_blind_go_on WHAT -- the one info line for _reinstall_adopt_blind's
# exception: WHAT failed, and why that is not a cluster. Said once per detection.
_reinstall_blind_go_on() {
  [[ -z "${_TB_REINSTALL_BLIND_SAID:-}" ]] || return 0
  _TB_REINSTALL_BLIND_SAID=1
  info "${1}. You cannot reach Docker (no DOCKER_HOST, and ${TB_DOCKER_DEFAULT_SOCKET} is not writable for you), so you cannot have started a k3d cluster, and prepare-host checked for one when it set k3s up."
}

# _reinstall_presence NAME -- _cluster_presence for NAME. CLUSTER_NAME is a global
# _cluster_presence reads; a local here shadows it for the call only.
_reinstall_presence() {
  local CLUSTER_NAME="$1" rc=0
  _cluster_presence || rc=$?
  return "$rc"
}

# _reinstall_record_cluster -- the k3d cluster the install record names. 0 and the
# name when the record says k3d; 0 and nothing when it names another substrate
# (that install recorded no k3d cluster); 1 when there is no record; 2 when it
# exists and cannot be read, names no substrate, or names a cluster that breaks
# the name rule: cannot tell, never absent.
_reinstall_record_cluster() {
  local rec text sub raw
  rec="$(tb_record_path)"
  [[ -e "$rec" ]] || return 1
  text="$(cat "$rec" 2>/dev/null)" || return 2
  sub="$(printf '%s' "$text" | _tb_record_substrate_in)" || return 2
  [[ "$sub" == "k3d" ]] || return 0
  raw="$(_tb_record_prior cluster_name "$text")"
  raw="${raw#\"}"; raw="${raw%\"}"
  _valid_cluster_name "$raw" || return 2
  printf '%s' "$raw"
}

_reinstall_add_other() {
  case " ${TB_REINSTALL_OTHERS} " in
    *" $1 "*) ;;
    *) TB_REINSTALL_OTHERS="${TB_REINSTALL_OTHERS:+${TB_REINSTALL_OTHERS} }$1" ;;
  esac
}

# _reinstall_read_how RC ERRFILE -- how a bounded read that returned RC went, in the
# words the go-on line and the cannot-tell refusal use: 0 "answered", 124 (_bounded's
# deadline) "did not answer", anything else "failed (<the last line it wrote to
# stderr>)", as _k3d_live_clusters quotes k3d (client-dev#1748).
_reinstall_read_how() {
  local msg=""
  case "$1" in
    0) printf 'answered' ;;
    124) printf 'did not answer' ;;
    *) [[ "$2" == /dev/null ]] || msg="$(awk 'NF { l = $0 } END { print l }' "$2" 2>/dev/null)"
       printf 'failed (%s)' "${msg:-exited $1 with no message}" ;;
  esac
}

_reinstall_cannot_tell() {
  TB_REINSTALL_FOUND="cannot-tell"; TB_REINSTALL_PROBE="$1"; TB_REINSTALL_REMEDY="$2"
  TB_REINSTALL_HOW="${3:-did not answer}"
}

# ── Decision ─────────────────────────────────────────────────────────────────

# _reinstall_consent -- the consent this run carries: the value of the variable the
# schema names (TB_REINSTALL_CONSENT_VAR), and ONLY under `offboard`. Under
# `refuse` it is never read, so no environment reaches the offboard.
_reinstall_consent() {
  [[ "${TB_K3D_REINSTALL:-}" == "offboard" ]] || return 0
  printf '%s' "${!TB_REINSTALL_CONSENT_VAR:-}"
}

# _reinstall_tty -- 0 when /dev/tty opens, so the CLI's typed-name prompt can
# reach the user. Under curl | bash stdin is the installer, so the prompt gets
# /dev/tty itself, as the sign-in does (provision.sh, _login_tty_ok).
_reinstall_tty() { { : </dev/tty; } 2>/dev/null; }

# _reinstall_consented -- 0 when this run can consent, and ONLY under `offboard`:
# the consent variable is set (passed to the CLI as --confirm-name), or a
# terminal is there for the CLI's own typed-name prompt. Under `refuse` neither
# the variable is read nor the terminal asked.
_reinstall_consented() {
  [[ -n "$(_reinstall_consent)" ]] && return 0
  [[ "${TB_K3D_REINSTALL:-}" == "offboard" ]] && _reinstall_tty
}

# _reinstall_decision -- refuse | offboard | proceed, from TB_REINSTALL_FOUND (run
# _reinstall_detect first) and the consent. proceed only where no k3d cluster can
# be here; offboard only for tracebloc's own k3d when this run can consent.
# Whether the consent names the right secure environment is the CLI's check
# (--confirm-name, or its prompt), so the CLI stays the one owner of it.
_reinstall_decision() {
  case "${TB_REINSTALL_FOUND:-cannot-tell}" in
    none) printf 'proceed\n' ;;
    tracebloc) if _reinstall_consented; then printf 'offboard\n'; else printf 'refuse\n'; fi ;;
    *) printf 'refuse\n' ;;
  esac
}

# _reinstall_explain -- what moving this machine means (D10), before a refusal
# and before an offboard alike.
_reinstall_explain() {
  warn "This machine runs tracebloc on k3d (cluster '${TB_REINSTALL_CLUSTER}')."
  hint "Moving it to native k3s is a reinstall: this machine's secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc."
  hint "To keep today's environment, unset TRACEBLOC_SUBSTRATE and re-run."
}

# ── The refusal ──────────────────────────────────────────────────────────────

# refuse_k3s_beside_live_k3d -- on a native k3s request, never k3s beside a live
# k3d. Returns 0 when this run may go on (no k3d here, or a consented offboard,
# which TB_REINSTALL_DECISION carries to main()); otherwise refuses by name, with
# what the move means (D10). Does nothing on any other substrate.
refuse_k3s_beside_live_k3d() {
  TB_REINSTALL_DECISION="proceed"
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] || return 0
  _reinstall_detect
  TB_REINSTALL_DECISION="$(_reinstall_decision)"
  case "$TB_REINSTALL_DECISION" in
    proceed|offboard) return 0 ;;
  esac
  # Every path below ends in error: a refusal, like the substrate refusals above it
  # in main(), so install_cleanup prints no "did not complete, try again" footer.
  # shellcheck disable=SC2034  # consumed cross-file by install_cleanup (common.sh)
  TB_EXIT_REFUSED=1
  case "$TB_REINSTALL_FOUND" in
    cannot-tell)
      error "This run cannot tell whether a k3d cluster is live on this machine: ${TB_REINSTALL_PROBE} ${TB_REINSTALL_HOW:-did not answer}, and native k3s is never set up beside a live k3d. ${TB_REINSTALL_REMEDY}" ;;
    other)
      warn "A k3d cluster that is not tracebloc's is on this machine: ${TB_REINSTALL_OTHERS}."
      hint "This installer never removes it. To keep tracebloc on k3d, unset TRACEBLOC_SUBSTRATE and re-run."
      error "Native k3s is never set up beside a live k3d." ;;
  esac
  _reinstall_explain
  if [[ "${TB_K3D_REINSTALL:-}" == "offboard" ]]; then
    hint "To move it, re-run on a terminal and type the secure environment's name when asked, or re-run with ${TB_REINSTALL_CONSENT_VAR}=<the secure environment's name>."
    error "Native k3s is never set up beside a live k3d, and no consent was given, so nothing was changed."
  fi
  error "Native k3s is never set up beside a live k3d, and this installer cannot move a k3d machine to native k3s yet."
}

# ── The offboard ─────────────────────────────────────────────────────────────

# _tb_cli SECONDS ARGS... -- the one way this file runs the tracebloc CLI, so a
# test can stand in for it. SECONDS is the deadline `_bounded` puts on the binary
# (the function itself cannot be handed to timeout(1), which execs its argument);
# 0 runs it bare, for the typed-name prompt only: timeout(1) moves its child out
# of the terminal's foreground process group, so a read from /dev/tty would be
# stopped (SIGTTIN), and a human is there to interrupt that one.
_tb_cli() {
  local t="$1"; shift
  if [[ "$t" == 0 ]]; then tracebloc "$@"; else _bounded "$t" tracebloc "$@"; fi
}

# _reinstall_on_tty CMD... -- CMD with all three streams on /dev/tty, for the
# CLI's typed-name prompt (split out so a test can run it without a terminal).
_reinstall_on_tty() { "$@" </dev/tty >/dev/tty 2>/dev/tty; }

# _reinstall_kube_context -- the context the old client runs in: the k3d record's
# kube_context, else k3d's own name for the cluster, k3d-<name>.
_reinstall_kube_context() {
  local text sub ctx=""
  if text="$(cat "$(tb_record_path)" 2>/dev/null)" \
     && sub="$(printf '%s' "$text" | _tb_record_substrate_in)" && [[ "$sub" == "k3d" ]]; then
    ctx="$(_tb_record_prior kube_context "$text")"
    ctx="${ctx#\"}"; ctx="${ctx%\"}"
    [[ "$ctx" != "null" ]] || ctx=""
  fi
  printf '%s' "${ctx:-k3d-${TB_REINSTALL_CLUSTER}}"
}

# _reinstall_stop WHY -- the offboard did not finish: say what is left, read
# again from _cluster_presence, and install nothing.
_reinstall_stop() {
  local p=0 name="${TB_REINSTALL_CLUSTER}"
  _reinstall_presence "$name" >/dev/null 2>&1 || p=$?
  case "$p" in
    0) hint "k3d cluster '${name}' is still on this machine." ;;
    1) hint "k3d cluster '${name}' is gone." ;;
    *) hint "Whether k3d cluster '${name}' is still on this machine cannot be told." ;;
  esac
  error "$1 Nothing was installed."
}

# reinstall_offboard_k3d -- the consented offboard (D10). `tracebloc delete
# --for-reinstall` revokes the old client and removes its k3d, and only then does
# step b install native k3s. main() calls this after step a, so every refusal
# there (sudo, disk, memory, preflight) has run, and before step b. It does
# nothing unless refuse_k3s_beside_live_k3d decided `offboard`, and the release
# switch reads `offboard`.
#
# The consent is the variable, passed as --confirm-name, or else the CLI's own
# typed-name prompt on /dev/tty. --yes and --force are never passed: a running
# training blocks the offboard, and the CLI's refusal is what the user reads.
# The CLI's exit code and k3d's own answer decide together. 0 goes on only when
# the cluster is definitely gone: the CLI also exits 0, with nothing removed, when
# its typed-name prompt is declined, left blank or cut short with Ctrl-C. 10
# (revoked, local teardown incomplete) goes on likewise only when the cluster is
# definitely gone. Anything else stops. The probe and the headless offboard each
# run under a deadline (TRACEBLOC_CLI_PROBE_TIMEOUT, TRACEBLOC_OFFBOARD_TIMEOUT), so
# a CLI that never answers stops the run with a message instead of holding a piped
# install for ever. 124 is that deadline: it never confirms the cluster is gone,
# so it stops like a declined prompt, and nothing is removed on a timeout.
reinstall_offboard_k3d() {
  [[ "${TB_REINSTALL_DECISION:-}" == "offboard" && "${TB_K3D_REINSTALL:-}" == "offboard" ]] || return 0
  local name="${TB_REINSTALL_CLUSTER}" consent ctx rc=0 p=0 probe=0 armed="${TRACEBLOC_RECORD_ARMED:-}" armed_old="${TB_RECORD_ARMED:-}"
  consent="$(_reinstall_consent)"
  _reinstall_explain
  info "Offboarding it first: tracebloc revokes this secure environment, then its k3d cluster '${name}' and its data are removed."
  # The record still describes the k3d install the CLI tears down by it, so
  # nothing this run does is written to it until the offboard is over.
  TRACEBLOC_RECORD_ARMED=""; TB_RECORD_ARMED=""   # both: the read falls back to the old name
  install_tracebloc_cli
  _tb_cli "${TB_CLI_PROBE_TIMEOUT:-30s}" delete --for-reinstall --help </dev/null >/dev/null 2>&1 || probe=$?
  [[ "$probe" -ne 124 ]] \
    || error "The tracebloc CLI on this machine did not answer within ${TB_CLI_PROBE_TIMEOUT:-30s} when asked whether it can offboard, so nothing was changed and k3d cluster '${name}' still runs. Check it with 'tracebloc --help' and re-run."
  [[ "$probe" -eq 0 ]] \
    || error "The tracebloc CLI on this machine cannot offboard a secure environment for a reinstall, so nothing was changed and k3d cluster '${name}' still runs. Update it with 'tracebloc upgrade' and re-run, or unset TRACEBLOC_SUBSTRATE to keep today's environment."
  ctx="$(_reinstall_kube_context)"
  if [[ -n "$consent" ]]; then
    _tb_cli "${TB_OFFBOARD_TIMEOUT:-15m}" delete --for-reinstall --context "$ctx" --confirm-name "$consent" </dev/null || rc=$?
  else
    _reinstall_on_tty _tb_cli 0 delete --for-reinstall --context "$ctx" || rc=$?
  fi
  case "$rc" in
    0)
      _reinstall_presence "$name" >/dev/null 2>&1 || p=$?
      [[ "$p" -eq 1 ]] || _reinstall_stop "The offboard did not finish: 'tracebloc delete' exited 0, but its k3d cluster is not gone, and native k3s is never set up beside a live k3d. A confirmation that was declined, left blank or cancelled ends this way. Re-run and type the secure environment's name to move this machine, or unset TRACEBLOC_SUBSTRATE to keep today's environment."
      ;;
    10)
      _reinstall_presence "$name" >/dev/null 2>&1 || p=$?
      [[ "$p" -eq 1 ]] \
        || _reinstall_stop "'tracebloc delete' revoked the old secure environment, but native k3s is never set up beside a live k3d. Check it with 'k3d cluster list', remove it with 'k3d cluster delete ${name}', then re-run."
      warn "The old secure environment is revoked and its k3d cluster is gone, but the CLI could not remove everything it left on this machine."
      ;;
    124) _reinstall_stop "The offboard did not finish within ${TB_OFFBOARD_TIMEOUT:-15m} ('tracebloc delete' was stopped), so how much of the secure environment it removed cannot be told. Re-run to finish it, with a longer TRACEBLOC_OFFBOARD_TIMEOUT if it needs more time." ;;
    1) _reinstall_stop "The offboard did not run ('tracebloc delete' exited 1), so the secure environment is untouched; the CLI's message above says why." ;;
    *) _reinstall_stop "The offboard stopped ('tracebloc delete' exited ${rc}); the CLI's message above says what it removed." ;;
  esac
  TRACEBLOC_RECORD_ARMED="$armed"; TB_RECORD_ARMED="$armed_old"
  # The move deletes the old data (the explanation above says so), and the
  # leftover guard below refuses a non-interactive run over any remnant. Its wipe
  # stays its own: scoped to HOST_DATA_DIR's data dirs, and verified.
  TB_LEFTOVER_ACTION=wipe
  success "Offboarded the old secure environment and removed k3d cluster '${name}'."
}
