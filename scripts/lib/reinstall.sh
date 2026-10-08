#!/usr/bin/env bash
# =============================================================================
#  reinstall.sh — a k3d machine moves to native k3s only through the offboard,
#  and native k3s is never set up beside a live k3d (RFC-0175 D10).
#
#  A k3d machine is reinstalled, not migrated: the installer detects it
#  read-only, says what the move means, and refuses. The consented offboard that
#  turns the refusal into a reinstall is behind the release switch, which ships
#  at `refuse` (TB_K3D_REINSTALL, stamped in common.sh from the schema's
#  x-tracebloc-reinstall block). Under `refuse` the consent variable is never
#  read, so nothing in the environment can reach an offboard.
#
#  main() calls refuse_k3s_beside_live_k3d right after the substrate refusals,
#  before the prepare-host dispatch and before validate_config, so nothing is
#  installed, written or started before it answers.
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
#      (client-dev#1606). Once k3d has answered, _cluster_presence decides whether
#      the cluster from step 3 is there (0 present, 1 absent, else cannot tell), and
#      every other listed cluster is another's.
#   5. with docker: _docker_answers, then the k3d-labelled containers, stopped ones
#      included. Docker not answering, or refusing this user, is cannot tell.
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
  local name="" rec_rc=0 has_k3d=0 has_docker=0 rc list n ps tracebloc=0 blind=0
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
  # refuse, refused now in its words, before it reaches _cluster_presence.
  name="${name:-${CLUSTER_NAME:-}}"
  _refuse_invalid_cluster_name "$name"

  if (( has_k3d )); then
    # The listing first: it alone tells a k3d that did not answer (start Docker) from
    # one that failed fast (quote it, client-dev#1606), and a fast failure is where
    # _reinstall_adopt_blind's exception applies. _cluster_presence, which cannot
    # tell the two apart, then decides tracebloc's own cluster once k3d has answered.
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
    if [[ "$lrc" -le 1 ]]; then
      rc=0; _reinstall_presence "$name" || rc=$?
      case "$rc" in
        0) tracebloc=1 ;;
        1) ;;
        *) _reinstall_cannot_tell "the k3d cluster listing ('k3d cluster list')" \
             "Start Docker so k3d can answer, then re-run."
           return 0 ;;
      esac
      # Only a listing that answered 0 lists clusters; 1 is none, whatever it printed.
      [[ "$lrc" -ne 0 ]] \
        || while IFS= read -r n; do [[ -z "$n" || "$n" == "$name" ]] || _reinstall_add_other "$n"; done <<<"$list"
    fi
  fi

  if (( has_docker )) && (( blind )) && ! _docker_answers; then
    _reinstall_blind_go_on "Docker ('docker info') does not answer you"
  elif (( has_docker )); then
    if ! _docker_answers; then
      _reinstall_cannot_tell "Docker ('docker info')" \
        "Start Docker, or run as a user Docker answers, then re-run."
      return 0
    fi
    rc=0
    ps="$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps -a --filter label=app=k3d --format '{{.Label "k3d.cluster"}}' 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      _reinstall_cannot_tell "Docker's container list ('docker ps')" \
        "Start Docker, or run as a user Docker answers, then re-run."
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

# _reinstall_decision -- refuse | offboard | proceed, from TB_REINSTALL_FOUND (run
# _reinstall_detect first) and the consent. proceed only where no k3d cluster can
# be here; offboard only for tracebloc's own k3d with consent given. Whether the
# consent names the right secure environment is the CLI's check (--confirm-name),
# so the CLI stays the one owner of it.
_reinstall_decision() {
  local consent
  consent="$(_reinstall_consent)"
  case "${TB_REINSTALL_FOUND:-cannot-tell}" in
    none) printf 'proceed\n' ;;
    tracebloc) if [[ -n "$consent" ]]; then printf 'offboard\n'; else printf 'refuse\n'; fi ;;
    *) printf 'refuse\n' ;;
  esac
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
  warn "This machine runs tracebloc on k3d (cluster '${TB_REINSTALL_CLUSTER}')."
  hint "Moving it to native k3s is a reinstall: this machine's secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc."
  hint "To keep today's environment, unset TRACEBLOC_SUBSTRATE and re-run."
  if [[ "${TB_K3D_REINSTALL:-}" == "offboard" ]]; then
    hint "To move it, re-run with ${TB_REINSTALL_CONSENT_VAR}=<the secure environment's name>."
    error "Native k3s is never set up beside a live k3d, and no consent was given, so nothing was changed."
  fi
  error "Native k3s is never set up beside a live k3d, and this installer cannot move a k3d machine to native k3s yet."
}
