#!/usr/bin/env bash
# =============================================================================
#  errors.sh — how a run fails and ends: error(), the failed-run block, the
#  refusals, the ERR-trap recorder, private scratch directories, the exit code
#  and install_cleanup. Sourced by install-k8s.sh.
# =============================================================================

# The command a person types to install, and to run the installer again;
# TRACEBLOC_INSTALL_CMD (the tuning knob TB_INSTALL_CMD) replaces it where it is set.
_TB_RERUN_CMD='bash <(curl -fsSL https://tracebloc.io/i.sh)'

# ── How a failed run ends ────────────────────────────────────────────────────
#  install_cleanup ends every failed run with one block (tb_end_failed): the ✖ line,
#  what to do with its command on its own line, and where the log is. The site that
#  decides the failure says what to do, right before it ends the run:
#    tb_fail_next TEXT [CMD]  TEXT (lines split on \n), then CMD under it: the install
#                             command when CMD is not given, none when it is "".
#    tb_fail_head TEXT        the ✖ line, in place of "Setup didn't finish".
#    tb_fail_firm             the remedy set stands where a later stop would say its own
#                             (preflight_sudo's no sudo).
#  A refusal that says nothing (TB_EXIT_REFUSED, no tb_fail_next) ends with its own line.
_TB_FAIL_HEAD=""; _TB_FAIL_NEXT=""; _TB_FAIL_CMD=""; _TB_FAIL_SET=""; _TB_FAIL_FIRM=""
tb_fail_next() {
  _TB_FAIL_NEXT="$1"; _TB_FAIL_SET=1
  if [[ $# -ge 2 ]]; then _TB_FAIL_CMD="$2"; else _TB_FAIL_CMD="${TB_INSTALL_CMD:-$_TB_RERUN_CMD}"; fi
}
tb_fail_head()  { _TB_FAIL_HEAD="$1"; }
tb_fail_firm()  { _TB_FAIL_FIRM=1; }
tb_fail_clear() { _TB_FAIL_HEAD=""; _TB_FAIL_NEXT=""; _TB_FAIL_CMD=""; _TB_FAIL_SET=""; _TB_FAIL_FIRM=""; }
tb_end_failed() {
  # The defaults sit in variables: an apostrophe inside "${v:-…}" breaks bash 3.2's parse.
  local head="Setup didn't finish" next="It's safe to run the installer again:" cmd="${TB_INSTALL_CMD:-$_TB_RERUN_CMD}" l logf
  [[ -z "$_TB_FAIL_HEAD" ]] || head="$_TB_FAIL_HEAD"
  [[ -z "$_TB_FAIL_NEXT" ]] || next="$_TB_FAIL_NEXT"
  [[ -z "$_TB_FAIL_SET" ]] || cmd="$_TB_FAIL_CMD"
  # Two blank lines before the rule, as before every section. Before the first step and
  # any ✖ line, the download block's own two are the last thing on screen (_TB_END_GAP).
  [[ -z "${_TB_END_GAP:-}" ]] || { echo ""; echo ""; }
  tb_rule
  echo ""
  echo -e "  ${TB_ERR}✖${RESET} ${head}"
  echo ""
  next="${next//\\n/$'\n'}"
  while IFS= read -r l; do if [[ -n "$l" ]]; then printf '  %s\n' "$l"; else echo ""; fi; done <<<"$next"
  [[ -z "$cmd" ]] || echo -e "    ${TB_CMD}${cmd}${RESET}"
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    logf="$LOG_FILE"
    if [[ -n "${HOME:-}" && "$logf" == "$HOME"/* ]]; then logf="~${logf#"$HOME"}"; fi
    echo ""
    echo -e "  ${TB_LABEL}Log:${RESET} ${logf}"
  fi
  echo ""
  tb_rule
}

# error_said PERSON MACHINE -- error, said twice: PERSON is the ✖ line a person reads
# (none when empty: the lines that say why are on screen already), MACHINE the whole
# reason, the one recorded, which machines and the install log read (tb_machine_lines).
error_said() {
  if declare -F _record_err >/dev/null 2>&1; then
    _record_err "${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}" "error: $2" 1
  fi
  tb_live_stop
  tb_machine_lines _tb_err_line "$2"
  if [[ -n "$1" ]]; then _tb_err_line "$1"; _TB_END_GAP=1; fi
  exit 1
}
_tb_err_line() { echo -e "  ${TB_ERR}✖ $*${RESET}" >&2; }
_TB_END_GAP=""

# tb_refused WHY ACCEPTED -- an answer that can't be used, on stderr (where `read -p`
# puts its prompt): the ✖ line says why, the next says what is accepted. The caller
# asks again: a mistyped answer never ends the run.
tb_refused() {
  log "Answer refused: $1"
  _tb_refused_lines "$1" "$2" >&2
}
_tb_refused_lines() { printf '  %s✖ %s%s\n    %s\n' "${TB_ERR:-}" "$1" "${RESET:-}" "$2"; }

# tb_choice_refused ANSWER CHOICES DEFAULT -- tb_refused for a choice prompt. CHOICES is
# as its brackets show them ("r/w/a" reads "r, w or a"), DEFAULT the one Enter takes.
tb_choice_refused() {
  local words="${2//\//, }"
  [[ "$words" != *", "* ]] || words="${words%, *} or ${words##*, }"
  tb_refused "\"$1\" isn't one of the choices." "Answer ${words}, or press Enter for $3."
}
# error MESSAGE — print and exit 1.
#
# It records itself first, and that is not decoration. `exit` fires NO ERR trap,
# so a deliberate refusal left TB_ERR_* holding whatever benign probe failed
# last — and install_cleanup then reported that probe as the cause. A real log
# read "Stopped at common.sh:527 — sudo -n true" for an install that died of a
# missing administrator password: line 527 is the passwordless-sudo probe, which
# is SUPPOSED to fail on a normal Mac. The report named a healthy check and sent
# the reader to the wrong place, which is worse than naming nothing.
#
# BASH_SOURCE[1]/BASH_LINENO[0] are the CALLER's file and line — where the
# refusal was decided. BASH_SOURCE[0] would name errors.sh every time.
error() {
  if declare -F _record_err >/dev/null 2>&1; then
    _record_err "${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}" "error: $*" 1
  fi
  tb_live_stop
  echo -e "  ${TB_ERR}✖ $*${RESET}" >&2
  _TB_END_GAP=1
  exit 1
}

# _refuse_foreign_client HEAD KEEP INSTEAD WHY -- end the run on a machine that already
# runs a secure environment this run must not replace (another account's, or another
# Client ID's): HEAD on the ✖ line, then the end block's KEEP, INSTEAD and the delete
# command. WHY and _release_client_fallback go to the log. One place for both sites.
#
# Why `tracebloc delete` and never a bare cluster delete: the backend record is
# anchored to the cluster's identity (the kube-system namespace UID), which dies with
# the cluster, so a delete that never calls the API strands the record on the
# dashboard for good. `tracebloc delete` releases it server-side first, then deletes it
# from this machine and, without --keep-data, wipes ~/.tracebloc: these sites mean a
# full removal. It acts with the SIGNED-IN account's token, hence `tracebloc login`.
_refuse_foreign_client() {
  tb_fail_next "${2}\n${3}" "tracebloc login && tracebloc delete"
  error_said "$1" "${4} $(_release_client_fallback)"
}

# _release_client_fallback -- how to delete it where `tracebloc delete` can't run (it
# refuses with "no active client" when the pointer is gone, or nobody can sign in as
# that account): on its dashboard, then, on Linux, native k3s's own uninstall script
# (k3s.sh, TB_K3S_UNINSTALL_PATH). A Mac gets no manual step.
_release_client_fallback() {
  local how="If tracebloc delete refuses, or nobody can sign in as that account, delete it on that account's dashboard"
  if [[ "${OS:-}" == "Linux" && -n "${TB_K3S_UNINSTALL_PATH:-}" ]]; then
    printf '%s, then delete k3s: sudo %s' "$how" "$TB_K3S_UNINSTALL_PATH"
  else
    printf '%s.' "$how"
  fi
}

# Execute-gate a freshly-installed tool. The old post-install "check" was a
# log-only interpolation (`... 2>/dev/null || echo present`) that masked failure,
# so a corrupt or wrong-architecture binary — a partial package-manager install, or a
# download no checksum path guarded — sat on PATH and failed only later, at
# cluster-create, after a green "System tools". Actually RUN the tool's cheapest
# self-check; on failure error() with an arch-aware remedy so the tool step fails
# loudly instead. NOTE: kubectl is gated with `version --client` (NOT --short,
# removed in kubectl 1.28+); helm with bare `version` (—short may go the same way).
#
# Removal is OPT-IN via a leading `--rm <path>`: pass it with the path where the
# installer PLACES the binary (TRACEBLOC_TOOLS_DIR/<tool>). On failure we remove that path
# ONLY when the binary that actually ran is that exact file (same inode, `-ef`).
# So: a broken binary WE installed there (fresh OR left by a prior run) is cleared,
# letting a re-run self-heal (Bugbot: otherwise `has` stays true → stuck loop);
# but a package manager's copy that lives elsewhere on PATH is never deleted — the
# resolved binary won't match our path (reviewer). Callers may pass --rm on every
# path; the `-ef` guard sorts out ownership.
# Usage: assert_tool_runs [--rm <placed-path>] <name> <version-arg>...
assert_tool_runs() {
  local rm_path=""
  if [[ "${1:-}" == "--rm" ]]; then rm_path="$2"; shift 2; fi
  local name="$1"; shift
  local out
  if out="$("$name" "$@" 2>&1)"; then
    # First line via pure-bash slicing, not `printf … | head -1`.
    # This one sits in ARGUMENT position, where a 141 does NOT trip errexit, so it
    # was never an abort — but the pipeline bought nothing and the shape is the
    # one being retired fleet-wide.
    log "$name OK: ${out%%$'\n'*}"
    return 0
  fi
  # Remove only the file we placed AND only if it's the binary that just failed.
  if [[ -n "$rm_path" && -f "$rm_path" ]]; then
    local resolved; resolved="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" -ef "$rm_path" ]] && rm -f "$rm_path" 2>/dev/null || true
  fi
  error "$name was installed but won't run — a corrupt or wrong-architecture binary (this machine is ${ARCH:-$(uname -m)}). Re-run the installer to re-download it; if it recurs, remove ${rm_path:-the $name on your PATH} (and any package-manager copy) first."
}

# ── Failure diagnostics ─────────────────────────────────────────
#  Under `set -euo pipefail` a command that fails outside an if/&&/|| context
#  kills the installer with NO output at all: the user got a generic "did not
#  complete", and the install log — which is the WHOLE session tee'd — recorded
#  nothing about why. A single ERR trap records where it died so both the log
#  and the closer can name it.
#
#  install-k8s.sh arms this with `set -E` (errtrace) so the trap is inherited by
#  functions and subshells — without it an ERR trap fires only at top level, and
#  every failure inside install_macos/install_linux (i.e. nearly all of them)
#  would still be invisible.
TRACEBLOC_ERR_LOC=""    # "file:line" of the LAST failing command — see _record_err
_TB_IN_RECORD_ERR=""   # re-entrancy guard; the recorder inherits its own trap
TB_ERR_CMD=""    # what failed. TWO producers, and they differ — read on before
                 # writing a message that ends up here.
                 #
                 #   ERR trap  → BASH_COMMAND, i.e. the command text UNEXPANDED:
                 #               `cmd "$VAR"`, never the value.
                 #   error()   → "error: $*", i.e. the message AS INTERPOLATED,
                 #               because a deliberate refusal fires no ERR trap
                 #               and would otherwise leave a benign probe here
                 # .
                 #
                 # So the old blanket "this cannot leak a credential into the
                 # log" no longer holds for the error() path, and TB_ERR_CMD
                 # reaches LOG_FILE twice — via _record_err and via
                 # install_cleanup's `FAILED at … command:` line.
                 #
                 # Every error() call today interpolates only paths, sizes,
                 # versions and arch names (audited). Keep it that way:
                 # NEVER interpolate a credential, token or password into an
                 # error() message. If you need one in the text, say
                 # "the credential file at $path", not the value.
TB_ERR_CODE=""   # its exit status (137/141/… included: a signal death is a failure)

# _record_err LOCATION COMMAND — ERR-trap body. Everything it needs about the
# failure is passed IN, because none of it survives being read from in here:
#   • `$?` must still be the FAILING command's status, so the trap calls this as
#     its very first command (parameter expansions cannot disturb `$?`);
#   • BASH_SOURCE/LINENO inside this function describe errors.sh, not the site
#     that failed;
#   • BASH_COMMAND tracks the CURRENTLY executing command, so by the time this
#     function runs its own first test it already reads as that test, not as the
#     command that failed.
# Always returns 0 — a recorder that failed would re-enter the trap.
_record_err() {
  local _code=$?
  # $3 overrides the implicit $?. The ERR trap has a meaningful $? and passes
  # nothing; error() does not (its $? is whatever preceded the call) and passes
  # the 1 it is about to exit with. Read before any other statement, or $? is
  # already clobbered.
  _code="${3:-$_code}"
  # Re-entrancy guard. `set -E` makes this function inherit the ERR trap, so any
  # command in here that fails would re-enter it — including `log` below, whose
  # `[[ -n "${LOG_FILE:-}" ]] && …` form returns non-zero when no log is open.
  # Every test also sits inside an `if` block for the same reason: a bare
  # `[[ … ]] && return 0` FAILS when the condition is false, which re-enters the
  # trap and records the guard itself as the failing command.
  if [[ -n "$_TB_IN_RECORD_ERR" ]]; then return 0; fi
  _TB_IN_RECORD_ERR=1

  # LAST failure wins — deliberately, and this is the whole point of the record.
  #
  # The ERR trap fires for EVERY failing command, including ones whose failure is
  # the expected answer: `_probe_privilege` runs `sudo -n true` and reads its
  # non-zero exit as "a password is needed", then prints that as a normal row in
  # the host check. First-wins latched onto exactly that probe and refused every
  # later record, so a run that died two steps afterwards reported the location of
  # a routine probe inside a step that SUCCEEDED — a wrong answer stated
  # confidently, which is worse than the blank screen it replaced.
  #
  # Last-wins is precise here because errexit stops the script AT the fatal
  # command and the trap fires once per failing command, with no per-frame
  # re-firing as the error unwinds — verified on bash 3.2 (macOS) and 5.x.
  TB_ERR_CODE="$_code"
  TRACEBLOC_ERR_LOC="${1:-?}"
  TB_ERR_CMD="${2:-}"

  # The full trail, log only. The benign entries are not noise: they are how you
  # tell a probe that always fails from the command that actually ended the run,
  # and reading them in order is what identified this bug.
  log "err: ${TRACEBLOC_ERR_LOC} exit=${TB_ERR_CODE} cmd=${TB_ERR_CMD}"

  _TB_IN_RECORD_ERR=""
  return 0
}

# ── Private scratch directories ───────────────────────────────
#  A download that lands under a FIXED name in /tmp can be written through by
#  another local account: /tmp is sticky, so a symlink someone else planted at
#  that name survives our `rm -f` (it fails silently — we don't own the entry)
#  and `curl -o` then writes wherever it points, as us. So every download and
#  scratch file goes in a directory mktemp just made for this run: ours, 0700,
#  with a name nobody could predict. On macOS TMPDIR is already per-user.
#
#  tb_scratch_dir VAR PREFIX — make the directory, assign its path to VAR, and
#  register it so install_cleanup removes it on ANY exit (error()'s exit 1, a
#  Ctrl-C, set -e). Registered rather than trapped: one EXIT trap per process,
#  and it is install_cleanup's. Trailing X's only — BSD mktemp needs them last.
#  Fails (non-zero, VAR untouched) when no directory could be made; the caller
#  decides, because writing to a fixed /tmp name instead is the bug this fixes.
#  tb_scratch_rm DIR — remove one now (the success path) and unregister it.
_TB_SCRATCH_DIRS="${_TB_SCRATCH_DIRS:-}"   # newline-separated, registration order
tb_scratch_dir() {
  local __var="$1" __prefix="$2" __dir
  __dir="$(mktemp -d "${TMPDIR:-/tmp}/${__prefix}-XXXXXX" 2>/dev/null)" || return 1
  [[ -n "$__dir" && -d "$__dir" ]] || return 1
  _TB_SCRATCH_DIRS="${_TB_SCRATCH_DIRS}${__dir}"$'\n'
  printf -v "$__var" '%s' "$__dir"
}
tb_scratch_rm() {
  local __dir="$1" __d __keep=""
  [[ -n "$__dir" ]] || return 0
  rm -rf "$__dir" 2>/dev/null || true
  while IFS= read -r __d; do
    [[ -n "$__d" && "$__d" != "$__dir" ]] && __keep="${__keep}${__d}"$'\n'
  done <<<"$_TB_SCRATCH_DIRS"
  _TB_SCRATCH_DIRS="$__keep"
}
# Reap every registered directory. Called from the EXIT traps; never fails.
tb_scratch_reap() {
  local __d
  while IFS= read -r __d; do
    [[ -n "$__d" ]] && { rm -rf "$__d" 2>/dev/null || true; }
  done <<<"$_TB_SCRATCH_DIRS"
  _TB_SCRATCH_DIRS=""
  return 0
}

# tb_exit_rc RC — the status an EXIT trap exits with. On
# macOS's bash 3.2 a `set -u` abort ("unbound variable") reaches the EXIT trap
# with `$?` = 0, and the trap's own last command then sets the process's status:
# an installer that died mid-run exited 0 and reported success. `exit N` and a
# `set -e` failure keep their status on every bash, so only a 0 is in doubt, and
# a 0 counts only once the script has said it meant one: every intended `exit 0`
# under the trap, and the normal end of install-k8s.sh, sets _tb_done=1 first.
# Any other 0 is read as the failure it was. Unset counts as not done.
tb_exit_rc() {
  if [[ "$1" -eq 0 && "${_tb_done:-0}" != 1 ]]; then echo 1; else echo "$1"; fi
}

# _tb_failed_footer -- a failed run's end as machines and the install log read it:
# the failing site (the command text stays in the log, never on screen), the
# log, and the support bundle. A person reads tb_end_failed.
_tb_failed_footer() {
  echo ""
  warn "Installation did not complete."
  if [[ -n "${TB_ERR_CODE:-}" ]]; then
    hint "Stopped at ${TRACEBLOC_ERR_LOC} (exit ${TB_ERR_CODE})."
  fi
  [[ -z "${LOG_FILE:-}" ]] || hint "Check the install log: $LOG_FILE"
  hint "This installer is safe to re-run — just try again."
  hint "If it keeps failing, re-run with --diagnose and send the bundle to tracebloc support."
}

# tb_end_of_run RC -- how a run that exits RC ends on screen. A failure ends with
# tb_end_failed, unless print_summary already reported the outcome
# (TRACEBLOC_CLIENT_STATE). A refusal (TB_EXIT_REFUSED) ends with it only when it said
# what to do (tb_fail_next): "run the installer again" would send the user straight
# back into the same refusal.
tb_end_of_run() {
  [[ "$1" -ne 0 && -z "${TRACEBLOC_CLIENT_STATE:-}" ]] || return 0
  if [[ -z "${TB_EXIT_REFUSED:-}" ]]; then
    tb_machine_lines _tb_failed_footer
    tb_end_failed
  elif [[ -n "$_TB_FAIL_SET" ]]; then
    tb_end_failed
  fi
  return 0
}

# ── Cleanup on exit ──────────────────────────────────────────────────────────
# install-k8s.sh wires it as `trap 'install_cleanup; exit "${_TB_EXIT_RC:-1}"' EXIT`:
# the explicit exit is what makes the status tb_exit_rc's on bash 3.2 too.
install_cleanup() {
  local exit_code=$?
  # Stop recording before doing anything else. This handler's own lines can fail
  # (a `kill` on a dead pid, an `[[ … ]]` that is simply false), and with `set -E`
  # each of those fires the ERR trap — which under last-wins would overwrite the
  # fatal command with a cleanup detail before the report below ever reads it.
  trap - ERR
  # A live line still drawing would run over the report below.
  tb_live_stop || true
  # A 0 nobody declared is an abort bash 3.2 lost the status of (tb_exit_rc), so
  # everything below — the footer and the telemetry outcome — sees a failure.
  if [[ $exit_code -eq 0 && "${_tb_done:-0}" != 1 ]]; then
    log "Exited 0 before the run declared it finished — read as a failure (an abort, e.g. an unbound variable under bash 3.2)."
  fi
  exit_code="$(tb_exit_rc "$exit_code")"
  _TB_EXIT_RC="$exit_code"
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  # Never leave the transient machine credential on disk: provision.sh sets
  # _PROVISION_CRED_FILE before minting and removes it after sourcing — this is the
  # backstop for an error/signal between mint and that cleanup.
  [[ -n "${_PROVISION_CRED_FILE:-}" ]] && rm -f "$_PROVISION_CRED_FILE" 2>/dev/null || true
  # The private download/scratch directories: a fatal error mid
  # download must not leave a partial binary behind in the user's TMPDIR.
  declare -F tb_scratch_reap >/dev/null 2>&1 && tb_scratch_reap
  # Record WHERE it died, always and first. The log is the artifact
  # users send to support, and until now a `set -e` death left it with no trace of
  # the failure at all. Logged even on the exit-2 / interrupted paths, so a
  # re-run-required stop that was actually caused by an error is still traceable.
  if [[ -n "${TB_ERR_CODE:-}" ]]; then
    log "FAILED at ${TRACEBLOC_ERR_LOC} — exit ${TB_ERR_CODE} — command: ${TB_ERR_CMD}"
  fi
  # A run that ends before its outcome (TRACEBLOC_CLIENT_STATE) stops the macOS node it started.
  if [[ $exit_code -ne 0 && -z "${TRACEBLOC_CLIENT_STATE:-}" ]] && declare -F _mac_ct_stop_run_node >/dev/null 2>&1; then
    _mac_ct_stop_run_node
  fi
  if [[ $exit_code -eq 2 ]]; then
    echo ""
    hint "Re-run required. Complete the step above, then run the script again."
    [[ -n "${LOG_FILE:-}" ]] && hint "Logs: $LOG_FILE"
  elif [[ $exit_code -eq 130 || $exit_code -eq 143 ]]; then
    # Interrupted, not broken. install-k8s.sh routes SIGINT/SIGTERM
    # through `exit 130`/`exit 143` so this trap still shreds the transient
    # credential — but funnelling those into "did not complete" told users their
    # own Ctrl-C was an installer failure, and made an interrupted run
    # indistinguishable from a real one in the log.
    echo ""
    warn "Installation was interrupted before it finished."
    [[ -n "${LOG_FILE:-}" ]] && hint "Log: $LOG_FILE"
    hint "Nothing is broken — this installer is safe to re-run."
  elif [[ $exit_code -ne 0 ]]; then
    tb_end_of_run "$exit_code"
  fi

  # One structured outcome event per install. Emitted LAST, from
  # the EXIT trap, so it runs on every path — success, the re-run-required stop,
  # Ctrl-C, and the fatal one — which is what §6.5 of the telemetry contract
  # requires and what makes a failure RATE computable rather than just a count.
  # Everything it reads (TRACEBLOC_CLIENT_STATE, TB_ERR_*, the phase clock) is final by
  # this point. Guarded for an older bootstrap that did not fetch telemetry.sh.
  if declare -F telemetry_emit_outcome >/dev/null 2>&1; then
    telemetry_emit_outcome "$exit_code" || true
  fi
}
