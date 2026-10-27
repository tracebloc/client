#!/usr/bin/env bash
# =============================================================================
#  reinstall.sh — native k3s is never set up on a machine that runs tracebloc on
#  k3d (RFC-0175 D10). This installer no longer moves such a machine: it stops
#  before anything is installed, written or started, says why in plain words, and
#  names the way off: a tracebloc CLI release that can still delete it. Over an
#  install record a degraded 'tracebloc delete' left behind, a yes on the terminal
#  sets the record aside and goes on (_reinstall_offer_way_out).
#
#  What says k3d is tracebloc's own data, never Docker or k3d: the install
#  record's substrate (with no substrate field, an artefact only k3d records),
#  else, on a machine whose install is older than the record, the kubeconfig
#  context k3d writes (_reinstall_k3d_said). main() calls
#  refuse_k3d_machine right after the substrate refusals, before the prepare-host
#  dispatch and before validate_config. prepare-host then asks the same of the
#  user it sets the machine up for (refuse_k3d_for_user), before step a writes.
# =============================================================================

# A tracebloc CLI release that can still delete such a setup with `tracebloc delete`:
# facts.env's RETIRED_OFFBOARD_CLI, stamped here by scripts/check-facts.sh.
TB_RETIRED_OFFBOARD_CLI="0.11.35"

# _reinstall_k3d_said -- whether tracebloc's own data says this machine runs on k3d.
# 0: it does; 1: it does not; 2: it cannot tell. TB_REINSTALL_SAID says what said
# so, or what could not be read; for 2, TB_REINSTALL_REMEDY says how to make it
# answer. It reads files only, in this order, and the first that exists decides:
#   1. the install record (tb_record_path): its substrate (_reinstall_record_says);
#   2. on Linux, the record's root copy, when this process reaches it without a
#      password (tb_substrate_resolve reads the two in the same order);
#   3. with no record at all: each kubeconfig file ($KUBECONFIG, else
#      ~/.kube/config) and its context k3d-<CLUSTER_NAME>, which k3d writes for
#      the cluster an install from before the record created.
_reinstall_k3d_said() {
  local rec dst text="" f ctx kc rc
  TB_REINSTALL_SAID=""; TB_REINSTALL_REMEDY=""
  rec="$(tb_record_path)"
  if [[ -e "$rec" ]]; then
    text="$(cat "$rec" 2>/dev/null)" || text=""
    _reinstall_record_says "the install record ${rec}" "$text" \
      "Check it is the file this installer wrote, or move it aside, then re-run."
    return
  fi
  if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] && dst="$(_tb_record_root_copy_path)" \
      && _tb_record_root_access && _tb_record_root_run test -e "$dst" 2>/dev/null; then
    text="$(_tb_record_root_run cat "$dst" 2>/dev/null)" || text=""
    _reinstall_record_says "the install record's root copy ${dst}" "$text" \
      "Check it is the file this installer wrote ('sudo cat ${dst}'), or move it aside, then re-run."
    return
  fi
  ctx="k3d-${CLUSTER_NAME:-}"
  kc="${KUBECONFIG:-${HOME:-}/.kube/config}"
  local IFS=:
  for f in $kc; do
    [[ -n "$f" && -e "$f" ]] || continue
    rc=0; _reinstall_kubeconfig_has "$ctx" "$f" || rc=$?
    case "$rc" in
      0) TB_REINSTALL_SAID="it has no install record (its install is older than the record), and your kubeconfig ${f} has the context '${ctx}', which k3d writes for a cluster named '${CLUSTER_NAME:-}'"
         return 0 ;;
      1) ;;
      *) TB_REINSTALL_SAID="there is no install record, and your kubeconfig ${f} cannot be read"
         TB_REINSTALL_REMEDY="Make it readable for you, or point KUBECONFIG away from it, then re-run."
         return 2 ;;
    esac
  done
  return 1
}

# _reinstall_record_says WHO TEXT REMEDY -- _reinstall_k3d_said's answer for the record
# WHO whose text is TEXT: 0 when its substrate is k3d, 1 for any other substrate, 2
# when it cannot tell (an empty TEXT is a record that could not be read). A substrate
# the record names decides over its artefacts; a record with no substrate field
# says k3d when it lists an artefact only k3d records (_reinstall_k3d_artefact).
_reinstall_record_says() {
  local sub name kind
  if sub="$(printf '%s' "$2" | _tb_record_substrate_in)"; then
    [[ "$sub" == "k3d" ]] || return 1
    TB_REINSTALL_SAID="${1} says so"
  elif [[ "$2" != *'"substrate"'* ]] && kind="$(_reinstall_k3d_artefact "$2")"; then
    TB_REINSTALL_SAID="${1} names no substrate, but lists a ${kind} artefact, which only a k3d install records"
  else
    TB_REINSTALL_SAID="${1} exists, but its substrate cannot be read from it"
    TB_REINSTALL_REMEDY="$3"
    return 2
  fi
  name="$(_tb_record_prior cluster_name "$2")"; name="${name#\"}"; name="${name%\"}"
  [[ -z "$name" || "$name" == null ]] || TB_REINSTALL_SAID+=" (cluster '${name}')"
  return 0
}

# _reinstall_k3d_artefact TEXT -- the first artefact kind the record text TEXT lists
# that only a k3d install records: a schema kind (TB_ARTEFACT_KINDS) named for k3d,
# as k3s-install is for k3s. Fails when it lists none, or its artefacts cannot be read.
_reinstall_k3d_artefact() {
  local arts k
  arts="$(printf '%s\n' "$1" | _tb_record_artefacts)" || return 1
  for k in ${TB_ARTEFACT_KINDS}; do
    [[ "$k" == k3d-* ]] || continue
    grep -qF -- "$(printf '{"kind": "%s",' "$k")" <<<"$arts" || continue
    printf '%s\n' "$k"
    return 0
  done
  return 1
}

# _reinstall_kubeconfig_has CONTEXT FILE -- 0 when the kubeconfig FILE lists CONTEXT
# under contexts: (_reinstall_context_in), 1 when it does not, 2 when FILE cannot be
# read.
_reinstall_kubeconfig_has() {
  local text
  text="$(cat "$2" 2>/dev/null)" || return 2
  _reinstall_context_in "$1" <<<"$text"
}

# _reinstall_context_in CONTEXT -- 0 when the kubeconfig text on stdin lists CONTEXT
# under contexts:, 1 when it does not. The layout is the one kubectl and k3d write:
# top-level keys at column 0, list items under them.
_reinstall_context_in() {
  # sprintf makes the quote characters, so no line holds an odd number of them:
  # customer-copy-no-ticket-refs.sh reads this body line by line.
  _TB_REINSTALL_CTX="$1" awk '
    BEGIN { want = ENVIRON["_TB_REINSTALL_CTX"]; q = sprintf("%c", 39); dq = sprintf("%c", 34); key = "^" dq "?name" dq "?[ \t]*:"; found = 0 }
    /^[^ \t#-]/ { sec = $0; sub(/[ \t]*:.*/, "", sec); gsub(dq, "", sec); next }
    sec == "contexts" {
      l = $0
      sub(/^[ \t]*(-[ \t]+)?/, "", l)
      if (l !~ key) next
      sub(key "[ \t]*", "", l)
      sub(/[ \t]+#.*$/, "", l); sub(/[ \t]+$/, "", l)
      f = substr(l, 1, 1)
      if ((f == dq || f == q) && length(l) >= 2 && substr(l, length(l), 1) == f) l = substr(l, 2, length(l) - 2)
      if (l == want) found = 1
    }
    END { exit !found }
  '
}

# _reinstall_exists_as USER FILE -- 0 when FILE exists as USER finds it, 1 when it
# does not, 2 when this run cannot ask as USER. USER root asks as root (tb_root_n),
# any other USER as them (tb_root_as); both are the root executor's, so --print asks
# as this user instead (common.sh, _tb_root_reads).
_reinstall_exists_as() {
  local a
  if [[ "$1" == root ]]; then
    a="$(tb_root_n sh -c "$TRACEBLOC_ROOT_SH_EXISTS" sh "$2" 2>/dev/null)" || a=""
  else
    a="$(tb_root_as "$1" sh -c "$TRACEBLOC_ROOT_SH_EXISTS" sh "$2" 2>/dev/null)" || a=""
  fi
  case "$a" in present) return 0 ;; absent) return 1 ;; *) return 2 ;; esac
}

# _reinstall_k3d_said_for USER HOME -- _reinstall_k3d_said's answer for the user
# prepare-host sets this machine up for, from USER's own data, never the
# administrator's: their record under HOME, its root copy keyed on USER, then their
# kubeconfig HOME/.kube/config (the administrator's KUBECONFIG is not theirs). Each
# file is read as its owner (_reinstall_exists_as); a file that cannot be looked for
# as its owner is refused as cannot tell (_reinstall_unread_as).
_reinstall_k3d_said_for() {
  local u="$1" h="$2" rec dst kc ctx text rc=0
  TB_REINSTALL_SAID=""; TB_REINSTALL_REMEDY=""
  rec="${h}${TB_RECORD_USER_PATH#\~}"
  _reinstall_exists_as "$u" "$rec" || rc=$?
  case "$rc" in
    0) text="$(tb_root_as "$u" cat "$rec" 2>/dev/null)" || text=""
       _reinstall_record_says "${u}'s install record ${rec}" "$text" \
         "Check it is the file this installer wrote, or move it aside, then re-run prepare-host."
       return ;;
    2) _reinstall_unread_as "$u" "${u}'s install record ${rec}"; return 2 ;;
  esac
  dst="$(_tb_record_root_path "$u")"; rc=0
  _reinstall_exists_as root "$dst" || rc=$?
  case "$rc" in
    0) text="$(tb_root_n cat "$dst" 2>/dev/null)" || text=""
       _reinstall_record_says "the install record's root copy ${dst}" "$text" \
         "Check it is the file this installer wrote, or move it aside, then re-run prepare-host."
       return ;;
    2) _reinstall_unread_as root "the install record's root copy ${dst}"; return 2 ;;
  esac
  ctx="k3d-${CLUSTER_NAME:-}"; kc="${h}/.kube/config"; rc=0
  _reinstall_exists_as "$u" "$kc" || rc=$?
  case "$rc" in
    1) return 1 ;;
    2) _reinstall_unread_as "$u" "${u}'s kubeconfig ${kc}"; return 2 ;;
  esac
  rc=0
  if text="$(tb_root_as "$u" cat "$kc" 2>/dev/null)"; then _reinstall_context_in "$ctx" <<<"$text" || rc=$?; else rc=2; fi
  case "$rc" in
    0) TB_REINSTALL_SAID="${u} has no install record (their install is older than the record), and their kubeconfig ${kc} has the context '${ctx}', which k3d writes for a cluster named '${CLUSTER_NAME:-}'"
       return 0 ;;
    1) return 1 ;;
  esac
  TB_REINSTALL_SAID="${u} has no install record, and their kubeconfig ${kc} cannot be read"
  TB_REINSTALL_REMEDY="Make it readable for ${u}, then re-run prepare-host."
  return 2
}

# _reinstall_unread_as USER WHAT -- refuse as cannot tell: WHAT cannot be looked for
# as USER. Its remedy names the sudo it needs, so it is said here, by error, and never
# kept in a variable (prepare-host-root-guard.py).
_reinstall_unread_as() {
  [[ "$1" != root ]] \
    || error "This run cannot tell whether this machine runs tracebloc on k3d, and native k3s is never set up beside it: ${2} cannot be read as root. Check that 'sudo true' works, then re-run prepare-host."
  error "This run cannot tell whether this machine runs tracebloc on k3d, and native k3s is never set up beside it: ${2} cannot be read as ${1}. Check that 'sudo -u ${1} true' works, then re-run prepare-host."
}

# refuse_k3d_machine -- stop the run by name when tracebloc's own data says this
# machine runs on k3d, or cannot tell (_reinstall_k3d_said); return 0 otherwise.
# Native k3s's own host refusals (_native_k3s_refuse_host) run first, so a host or
# a setting native k3s does not serve is refused before step a installs anything.
refuse_k3d_machine() {
  local rc=0
  declare -F _native_k3s_refuse_host >/dev/null 2>&1 \
    || error "This installer build can't check whether native k3s can run here (stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
  # Every exit below is a refusal, so install_cleanup prints no "try again" footer.
  # shellcheck disable=SC2034  # consumed cross-file by install_cleanup (common.sh)
  TB_EXIT_REFUSED=1
  _native_k3s_refuse_host
  _reinstall_k3d_said || rc=$?
  _reinstall_refuse "$rc" open && return 0
  # The way out lives here, never in _reinstall_refuse: prepare-host's refusal shares
  # that, and the way out runs sudo outside tb_root (prepare-host-root-guard.py).
  if _reinstall_offer_way_out; then
    TB_EXIT_REFUSED=""
    return 0
  fi
  error "Nothing was changed."
}

# refuse_k3d_for_user USER HOME -- prepare-host's refusal: stop by name when the
# data of USER, whose home is HOME, says they run tracebloc on k3d, or cannot tell
# (_reinstall_k3d_said_for); return 0 otherwise. prepare-host calls it once its
# password is in and before step a writes anything; main() has already run
# refuse_k3d_machine over the administrator's own data.
refuse_k3d_for_user() {
  local rc=0
  _reinstall_k3d_said_for "$1" "$2" || rc=$?
  _reinstall_refuse "$rc"
}

# _reinstall_refuse RC [open] -- the refusal for the answer RC of _reinstall_k3d_said
# or _reinstall_k3d_said_for: 1 returns 0, 2 refuses as cannot tell, 0 refuses with the
# way off k3d. With open, that last returns 3 after the way off, and the caller ends
# the refusal (refuse_k3d_machine's way out).
_reinstall_refuse() {
  local engine="native k3s"
  # A Mac names its one runtime, as tb_substrate_resolve's refusal there does; a build
  # whose map leaves a Mac no one runtime names the substrate this run resolved.
  if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Darwin" ]]; then
    engine="$(_tb_substrate_fresh_here)" || engine="${TRACEBLOC_SUBSTRATE_RESOLVED:-}"
    engine+=" in Apple's container runtime"
  fi
  # shellcheck disable=SC2034  # consumed cross-file by install_cleanup (common.sh)
  case "$1" in
    1) TB_EXIT_REFUSED=""; return 0 ;;
    2) error "This run cannot tell whether this machine runs tracebloc on k3d, and ${engine} is never set up beside it: ${TB_REINSTALL_SAID}. ${TB_REINSTALL_REMEDY}" ;;
  esac
  warn "This machine runs tracebloc on k3d: ${TB_REINSTALL_SAID}."
  hint "This installer no longer sets up k3d, and it never sets up ${engine} beside it."
  hint "Moving this machine to ${engine} is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc."
  hint "To move it, delete that secure environment with 'tracebloc delete', then run this installer again."
  hint "If 'tracebloc delete' refuses, tracebloc CLI ${TB_RETIRED_OFFBOARD_CLI} can still delete it."
  # install-cli.sh's URL; a bootstrap that did not fetch install-cli.sh names the release only.
  [[ -z "${TRACEBLOC_CLI_INSTALL_URL:-}" ]] \
    || hint "Install that CLI with:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh -s -- --version v${TB_RETIRED_OFFBOARD_CLI}"
  [[ "${2:-}" != open ]] || return 3
  error "Nothing was changed."
}

# _reinstall_stamp -- the UTC time a record set aside is named for.
_reinstall_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# _reinstall_root_copy -- the path of the install record's root copy when this run
# reaches it and it exists (Linux); fails otherwise.
_reinstall_root_copy() {
  local dst
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 1
  dst="$(_tb_record_root_copy_path)" && _tb_record_root_access && _tb_record_root_run test -e "$dst" 2>/dev/null || return 1
  printf '%s' "$dst"
}

# _reinstall_live_context RECORD-TEXT -- 0 when a kubeconfig has k3d's context for the
# cluster the record names or for CLUSTER_NAME, setting TB_REINSTALL_LIVE_CTX and
# TB_REINSTALL_LIVE_FILE; 1 when none does; 2 when none does and a kubeconfig that
# exists could not be read (TB_REINSTALL_LIVE_FILE names it). Reads every file in
# $KUBECONFIG and ~/.kube/config.
_reinstall_live_context() {
  local f name names files rc unread=""
  name="$(_tb_record_prior cluster_name "$1")"; name="${name#\"}"; name="${name%\"}"
  [[ "$name" != null ]] || name=""
  names="${name}:${CLUSTER_NAME:-}"
  files="${KUBECONFIG:+${KUBECONFIG}:}${HOME:-}/.kube/config"
  local IFS=:
  for f in $files; do
    [[ -n "$f" && -e "$f" ]] || continue
    for name in $names; do
      [[ -n "$name" ]] || continue
      rc=0; _reinstall_kubeconfig_has "k3d-${name}" "$f" || rc=$?
      case "$rc" in
        0) TB_REINSTALL_LIVE_CTX="k3d-${name}"; TB_REINSTALL_LIVE_FILE="$f"; return 0 ;;
        1) ;;
        *) [[ -n "$unread" ]] || unread="$f"; break ;;
      esac
    done
  done
  [[ -z "$unread" ]] || { TB_REINSTALL_LIVE_FILE="$unread"; return 2; }
  return 1
}

# _reinstall_offer_way_out -- the way past a refusal over an install record whose
# 'tracebloc delete' could not finish, so the record stayed. On a terminal, one
# question: only an explicit yes moves the record (and on Linux its root copy) to
# <record>.k3d-retired-<UTC time>, never deleting it, lists what the record says k3d
# left behind, and returns 0. Any other answer, and a run with no terminal, return 1
# (the latter after naming the mv commands). With no record to set aside, it says nothing.
# While a kubeconfig has k3d's context, or cannot be read, the cluster may still exist: no way out is offered.
_reinstall_offer_way_out() {
  local rec root stamp ans="" text="" line kind id path listed="" rc
  rec="$(tb_record_path)"; [[ -e "$rec" ]] || rec=""
  root="$(_reinstall_root_copy)" || root=""
  [[ -n "${rec}${root}" ]] || return 1
  if [[ -n "$rec" ]]; then text="$(cat "$rec" 2>/dev/null)" || text=""
  else text="$(_tb_record_root_run cat "$root" 2>/dev/null)" || text=""; fi
  rc=0; _reinstall_live_context "$text" || rc=$?
  case "$rc" in
    0) hint "The k3d cluster '${TB_REINSTALL_LIVE_CTX#k3d-}' may still exist: your kubeconfig ${TB_REINSTALL_LIVE_FILE} has the context '${TB_REINSTALL_LIVE_CTX}'. Run 'tracebloc delete' and let it finish, then run this installer again."
       return 1 ;;
    1) ;;
    *) hint "Your kubeconfig ${TB_REINSTALL_LIVE_FILE} cannot be read, so the k3d cluster may still exist. Make it readable for you, or point KUBECONFIG away from it, then run this installer again."
       return 1 ;;
  esac
  stamp="$(_reinstall_stamp)"
  if ! { declare -F _prompt_tty >/dev/null 2>&1 && _prompt_tty; }; then
    hint "If 'tracebloc delete' ran and could not finish, set the install record aside yourself, then run this installer again:"
    [[ -z "$rec" ]] || hint "  mv ${rec} ${rec}.k3d-retired-${stamp}"
    [[ -z "$root" ]] || hint "  sudo mv ${root} ${root}.k3d-retired-${stamp}"
    return 1
  fi
  printf '\n  Set the old install record aside and go on? Answer yes only if '"'"'tracebloc delete'"'"' ran and could not finish. [y/N] '
  IFS= read -r ans <"${TRACEBLOC_TTY:-/dev/tty}" || ans=""
  echo ""
  ans="$(printf '%s' "${ans//[[:space:]]/}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == y || "$ans" == yes ]] || return 1
  if [[ -n "$root" ]]; then
    _tb_record_root_run mv -- "$root" "${root}.k3d-retired-${stamp}" \
      || error "Couldn't set the install record's root copy ${root} aside. Nothing was changed."
    hint "Set aside, not deleted: ${root} -> ${root}.k3d-retired-${stamp}"
  fi
  if [[ -n "$rec" ]]; then
    mv -- "$rec" "${rec}.k3d-retired-${stamp}" \
      || error "Couldn't set the install record ${rec} aside."
    hint "Set aside, not deleted: ${rec} -> ${rec}.k3d-retired-${stamp}"
  fi
  while IFS='|' read -r kind id path; do
    [[ -n "$kind" ]] || continue
    if [[ -z "$listed" ]]; then
      hint "The old install record lists what k3d left behind. Delete these yourself:"
      listed=1
    fi
    hint "  - ${kind} '${id}'${path:+ at ${path}}"
  done < <(printf '%s\n' "$text" | _tb_record_artefacts 2>/dev/null \
    | sed -nE 's/^[{]"kind": "([^"]*)", "id": "([^"]*)", "path": (null|"([^"]*)"),.*/\1|\2|\4/p')
  return 0
}
