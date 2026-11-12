#!/usr/bin/env bash
# =============================================================================
#  output.sh — the installer's output: the colour palette, the logging helpers
#  (info, success, warn, step, log, hint), step headers, the xtrace hold, the
#  install log, the banner and the help text. Sourced by install-k8s.sh.
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
# One brand-grounded palette (design-system tokens): cyan #01a5cc = structure,
# lime #91e947 = action — mirrors the Go CLI's internal/ui engine. Each tone
# renders as exact 24-bit hex on a truecolor terminal, the nearest ANSI-16
# elsewhere, its deep shade on a light background, and nothing at all when colour
# is off (NO_COLOR / not a TTY / TERM=dumb / TRACEBLOC_PLAIN=1). Meaning never rests on
# hue alone — headings/commands also carry bold and alerts a distinct glyph.
#
# Decided ONCE here, at source time: output.sh is sourced before setup_log_file
# redirects stdout through `tee`, so the `-t 1` test sees the real terminal.
if [[ -n "${NO_COLOR:-}" || "${TRACEBLOC_PLAIN:-}" == "1" || "${TERM:-}" == "dumb" || ! -t 1 ]]; then
  _tb_mode=none
elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
  _tb_mode=true
else
  _tb_mode=16
fi
# Whether a person watches stdout, decided here for the same reason as the colour
# mode. Lines only a machine reads (the substrate line, the host check) go to the
# install log alone when one does (tb_machine_lines).
if [[ -t 1 ]]; then _TB_STDOUT_TTY=1; else _TB_STDOUT_TTY=""; fi
_tb_bg=dark
if [[ -n "${COLORFGBG:-}" ]]; then
  _tb_last="${COLORFGBG##*;}"           # "fg;bg" → a trailing 7/15 is a light bg
  [[ "$_tb_last" == "7" || "$_tb_last" == "15" ]] && _tb_bg=light
fi

# _sgr DARK_RGB LIGHT_RGB ANSI16 BOLD UNDERLINE → the opening escape for a tone
# (empty when colour is off). RGB args are "R;G;B"; emits the literal \033[…m form
# so both `echo -e` and printf format strings interpret it, matching legacy usage.
_sgr() {
  [[ "$_tb_mode" == "none" ]] && return 0
  local codes
  if [[ "$_tb_mode" == "true" ]]; then
    if [[ "$_tb_bg" == "light" ]]; then codes="38;2;$2"; else codes="38;2;$1"; fi
  else
    codes="$3"
  fi
  [[ "$4" == "1" ]] && codes="${codes};1"
  [[ "$5" == "1" ]] && codes="${codes};4"
  printf '\\033[%sm' "$codes"
}

# Semantic tones (the same table as internal/ui/ui.go).
TB_HEADING="$(_sgr '1;165;204'  '1;99;122'   36 1 0)"  # cyan bold — structure/headings
TB_CMD="$(_sgr     '145;233;71' '87;140;43'  32 1 0)"  # lime bold — the thing to run
TB_DESC="$(_sgr    '167;237;108' '87;140;43' 32 0 0)"  # soft lime — supporting text
TB_LINK="$(_sgr    '1;165;204'  '1;99;122'   36 0 1)"  # cyan underline — destinations
TB_ACCENT="$(_sgr  '1;165;204'  '1;99;122'   36 0 0)"  # cyan — prompt guidance
TB_GO="$(_sgr      '145;233;71' '87;140;43'  32 0 0)"  # lime — ✔ / ● (good/go)
TB_WARN="$(_sgr    '255;198;43' '138;106;0'  33 0 0)"  # amber — ⚠
TB_ERR="$(_sgr     '246;76;76'  '192;39;31'  31 1 0)"  # red bold — ✖
TB_ERRSOFT="$(_sgr '246;76;76'  '192;39;31'  31 0 0)"  # red — ✗ offline
TB_LABEL="$(_sgr   '142;142;142' '107;107;107' 2 0 0)" # dim neutral — labels

# Structural (weight only) + reset — also honour the off switch.
if [[ "$_tb_mode" == "none" ]]; then
  BOLD=''; DIM=''; WHITE=''; RESET=''
else
  BOLD='\033[1m'; DIM='\033[2m'; WHITE='\033[1;37m'; RESET='\033[0m'
fi

# Legacy names, kept so untouched call sites still render on-brand AND honour the
# off switch: CYAN → cyan accent, GREEN → go/lime, YELLOW → warn, RED → error.
CYAN="$TB_ACCENT"; GREEN="$TB_GO"; YELLOW="$TB_WARN"; RED="$TB_ERRSOFT"

# ── Logging ──────────────────────────────────────────────────────────────────
#  info()          — supplementary detail shown to user (dim bullet)
#  success()       — completed item (green checkmark)
#  warn()          — non-blocking warning (yellow triangle)
#  error()         — fatal error (bold red cross, exits)
#  step()          — major step header: step <n> <total> "label"
#  log()           — debug only, writes to LOG_FILE, never shown to user
#  prompt_header() — bold label before user input prompts
#  hint()          — dim contextual help text
info()           { _tb_live_hold; echo -e "  ${DIM}·${RESET} $*"; _tb_live_resume; }
success()        { _tb_live_hold; echo -e "  ${TB_GO}✔${RESET} $*"; _tb_live_resume; }
warn()           { _tb_live_hold; echo -e "  ${TB_WARN}⚠${RESET}  $*"; _tb_live_resume; }
# A note of a few short lines: the glyph and the first line, the rest indented
# under it. warn_note for a caution, info_note for something to know.
_tb_note() {
  local glyph="$1" tone="$2" l
  shift 2
  _tb_live_hold
  echo -e "  ${tone}${glyph}${RESET} $1"
  shift
  for l in "$@"; do echo -e "    $l"; done
  _tb_live_resume
}
warn_note()      { _tb_note "⚠" "$TB_WARN" "$@"; }
info_note()      { _tb_note "·" "$DIM" "$@"; }
# tb_machine_lines CMD [ARG...] -- run CMD, whose lines a machine reads (e2e, CI) and a
# person does not need: on stdout when nobody watches it, into the install log only
# when a person does (_TB_STDOUT_TTY).
tb_machine_lines() {
  if [[ -n "${_TB_STDOUT_TTY:-}" ]]; then
    "$@" >>"${LOG_FILE:-/dev/null}" 2>&1
  else
    "$@"
  fi
}

step()           { echo -e "\n${TB_HEADING}Step $1/$2${RESET}  ${BOLD}$3${RESET}"; }
log()            { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null; return 0; }
prompt_header()  { echo -e "\n  ${BOLD}${WHITE}$*${RESET}"; }
hint()           { _tb_live_hold; echo -e "  ${DIM}$*${RESET}"; _tb_live_resume; }

# The rule above and below the banner and the final summary.
tb_rule()        { echo -e "  ${DIM}─────────────────────────────────────────────${RESET}"; }

# step_header LETTER [TOTAL] TITLE — bold running header for one of the install's
# steps (a–f) in the first-run run-through, numbered by its letter out of TOTAL
# (default TB_INSTALL_STEPS), e.g. `step_header a "Checking your machine"` →
# "  [1/6] Checking your machine". A TOTAL of 1 prints the title alone (a flow of one
# step, prepare-host). Prints the header + a single trailing blank; the blank-line
# gap BETWEEN steps comes from each step body ending with a blank line (main() adds
# it), matching the run-through's spacing.
#
# It is also where the install's phase clock turns over. Hooking
# THIS rather than adding a telemetry_phase_begin call to each of the six steps
# is the difference between phase timings that are correct by construction and
# phase timings that are correct for the steps somebody remembered — and the
# letters it is keyed on are the ones actually being printed, so nothing can
# drift. Guarded because telemetry.sh may be absent under an older bootstrap
# whose FILES list did not fetch it, and the `|| true` because printing a step
# header must never be able to end an install.
# The install's steps: install-k8s.sh's main() has one step_header for each
# (common.bats holds the two to agreeing).
TB_INSTALL_STEPS=6
step_header()    {
  local letter="$1" total="$TB_INSTALL_STEPS" n
  if [[ $# -ge 3 ]]; then total="$2"; shift; fi
  if declare -F telemetry_phase_begin >/dev/null 2>&1; then
    telemetry_phase_begin "$letter" || true
  fi
  n=$(( $(printf '%d' "'$letter") - 96 ))
  # From the first step on, a failed run's end block opens with the gap a section has.
  _TB_END_GAP=1
  # The Windows installer's client run goes over steps a-c again, after the cluster
  # run showed them as [1/6]-[3/6]: one header for the three, so the screen's one
  # sequence goes on at [4/6] and does not start over.
  if _tb_step_rechecked "$letter"; then
    [[ "$letter" != a ]] || { echo -e "  ${TB_HEADING}Checking your secure environment${RESET}"; echo ""; }
    return 0
  fi
  if [[ "$total" == 1 ]]; then
    echo -e "  ${TB_HEADING}$2${RESET}"; echo ""
  else
    echo -e "  ${TB_HEADING}[${n}/${total}] $2${RESET}"; echo ""
  fi
}

# _tb_step_rechecked LETTER -- step LETTER is one the Windows installer's cluster run
# showed already: a, b or c, in the client run in tracebloc's WSL distro. Nowhere else.
_tb_step_rechecked() {
  [[ "$1" == [abc] ]] || return 1
  declare -F tb_wsl_phase >/dev/null 2>&1 || return 1
  [[ "$(tb_wsl_phase 2>/dev/null)" == client ]]
}

# step_end LETTER -- the gap after step LETTER's body: two blank lines, and none
# inside the client run's one header for steps a-c (step_header).
step_end() {
  if [[ "$1" == [ab] ]] && _tb_step_rechecked "$1"; then return 0; fi
  echo ""; echo ""
}

# ── Secrets and bash -x ──────────────────────────────────────────────────────
# Run under `bash -x` (the usual way to debug a run), every command and assignment
# is traced to stderr, and setup_log_file tees stderr into the install log, which a
# diagnose bundle carries. A secret held in a variable, passed as an argument or read
# from a file would be traced with it. So the code that holds one runs with xtrace
# held off, and puts the caller's xtrace back when it is done:
#   * inline: `{ _tb_trace_off; } 2>/dev/null` ... `_tb_trace_on` (the braces keep the
#     helper's own lines out of the trace). Holds nest; only the outermost restores.
#   * a whole function: NAME is a one-line wrapper written beside it, in its own file
#     (so BASH_SOURCE and BASH_LINENO, which error() and the ERR trap record, name
#     that file), holding xtrace off around _tb_untraced_NAME, the function itself.
#     The wrapper's own call is still traced, so a caller passing a secret in its
#     arguments holds xtrace off itself. scripts/tests/common.bats checks each
#     inline hold is released on its way out.
# A secret-holding stretch that exits (error) leaves xtrace off, which hides more,
# never less.
_TB_TRACE_HOLD=0; _TB_TRACE_WAS=""
_tb_trace_off() {
  if [[ "${_TB_TRACE_HOLD:-0}" -le 0 ]]; then
    _TB_TRACE_HOLD=0
    case "$-" in *x*) _TB_TRACE_WAS=1 ;; *) _TB_TRACE_WAS="" ;; esac
  fi
  _TB_TRACE_HOLD=$(( ${_TB_TRACE_HOLD:-0} + 1 ))
  set +x
}
_tb_trace_on() {
  _TB_TRACE_HOLD=$(( ${_TB_TRACE_HOLD:-1} - 1 ))
  if [[ "$_TB_TRACE_HOLD" -le 0 ]]; then
    _TB_TRACE_HOLD=0
    [[ -z "${_TB_TRACE_WAS:-}" ]] || set -x
  fi
  return 0
}

# ── Log file — captures all stdout/stderr alongside the terminal ─────────────
# The install log's file name, declared once. <stamp> is `date +%Y%m%d-%H%M%S`.
# In tracebloc's WSL distro both of the Windows installer's runs log into one
# directory (TRACEBLOC_LOG_DIR), so the name carries the run: <phase> is one of
# TB_WSL_PHASES below. e2e picks a run's log by it,
# and install-wsl.ps1's Pester case holds its phase names to TB_WSL_PHASES: change
# the names here, nowhere else. Every reader globs install-*.log.
TB_INSTALL_LOG_NAME='install-<stamp>.log'
TB_INSTALL_LOG_NAME_WSL='install-<stamp>-<phase>.log'
# Choose the log-file path: under host_data_dir when it's creatable AND writable,
# else a temp file — so setup_log_file never dies on a bare `mkdir -p`/`tee`.
# This matters for prepare-host, which logs BEFORE the data-dir guard runs: on an NFS
# home under sudo + root_squash the data dir isn't creatable/writable yet, and a
# cryptic mkdir failure there predates any friendly message. (The full install's
# early_data_dir_guard still refuses a network DATA dir before this runs.) Pure-ish
# (prints the path; no exec redirect) so it's unit-testable.
_choose_log_file() {
  local candidate="" dir="${host_data_dir:-}" phase="" name
  # TRACEBLOC_LOG_DIR: where the Windows installer wants the core's log when it runs
  # it in tracebloc's WSL distro -- %USERPROFILE%\.tracebloc, as the distro sees it
  # -- so the user finds it on Windows, beside the
  # host's own files. Unset everywhere else, where the data dir holds the log.
  if [[ -n "${TRACEBLOC_LOG_DIR:-}" ]]; then dir="$TRACEBLOC_LOG_DIR"; fi
  # Both of the Windows installer's runs log there, so the name says which run wrote
  # it (TB_INSTALL_LOG_NAME_WSL). Outside the distro there is no phase, and the name
  # is TB_INSTALL_LOG_NAME.
  phase="$(tb_wsl_phase)" || phase=""
  name="$TB_INSTALL_LOG_NAME"
  [[ -z "$phase" ]] || name="$TB_INSTALL_LOG_NAME_WSL"
  name="${name//<stamp>/$(date +%Y%m%d-%H%M%S)}"
  name="${name//<phase>/$phase}"
  if mkdir -p "$dir" 2>/dev/null; then
    candidate="${dir}/${name}"
    : >"$candidate" 2>/dev/null || candidate=""   # confirm it's actually writable
  fi
  # Trailing X's (no suffix after): BSD mktemp (macOS) requires the X's at the END
  # of the template, GNU accepts it too — a `.log` suffix would break macOS.
  [[ -n "$candidate" ]] || candidate="$(mktemp "${TMPDIR:-/tmp}/tracebloc-install-XXXXXX" 2>/dev/null || echo /dev/null)"
  printf '%s' "$candidate"
}

setup_log_file() {
  LOG_FILE="$(_choose_log_file)"
  # Fd 7 keeps the terminal for the live line's frames (_tb_tty); the log gets lines only.
  exec 7>&1 && _TB_TTY_FD=7
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Install log: $LOG_FILE"
  # The substrate line printed before the log existed goes into it too, verbatim
  # (not through log(), whose timestamp would bend the grammar).
  if [[ -n "${TB_SUBSTRATE_TOKEN_PRINTED:-}" ]]; then
    tb_substrate_token >>"$LOG_FILE" 2>/dev/null || true
  fi
  log "Substrate: ${TRACEBLOC_SUBSTRATE_RESOLVED}, from ${TB_SUBSTRATE_SOURCE:-the default}."
  if [[ -n "${TB_SUBSTRATE_NOTE:-}" ]]; then log "$TB_SUBSTRATE_NOTE"; fi
  if [[ -n "${TB_SUBSTRATE_MOVED:-}" ]]; then log "$TB_SUBSTRATE_MOVED"; fi
}

# ── Banner ───────────────────────────────────────────────────────────────────
#  The first-run title: "tracebloc · <version>", then "Setting up tracebloc on your
#  machine". In the curl|bash path the bootstrap (install.sh) already drew this above
#  its "Downloading" section and exported TRACEBLOC_BANNER_SHOWN, so we don't draw
#  a second one; on the direct ./install-k8s.sh path we draw it here.
print_banner() {
  if [[ -n "${TRACEBLOC_BANNER_SHOWN:-}" ]]; then
    log "Banner already shown by the bootstrap — not redrawing."
    log "OS=$OS  Arch=$ARCH  Cluster='$cluster_name'"
    return 0
  fi
  echo ""
  echo ""
  if [[ -n "${TB_VERSION:-}" ]]; then
    echo -e "  ${BOLD}${CYAN}tracebloc${RESET}${DIM} · ${TB_VERSION}${RESET}"
  else
    echo -e "  ${BOLD}${CYAN}tracebloc${RESET}"
  fi
  echo ""
  echo -e "  Setting up tracebloc on your machine"
  echo ""
  tb_rule
  echo ""
  echo ""
  log "OS=$OS  Arch=$ARCH  Cluster='$cluster_name'"
  log "Host data dir: $host_data_dir → /tracebloc (inside k3s nodes)"
}

# ── Help ─────────────────────────────────────────────────────────────────────
print_help() {
  cat <<'HELP'
tracebloc installer

  Sets up your secure environment on this machine
  and connects it to tracebloc.

Usage:
  bash <(curl -fsSL https://tracebloc.io/i.sh) [options]
  ./install-k8s.sh [options]

Options:
  --diagnose      Save a support bundle to ~/.tracebloc and exit.
                  Send it to tracebloc support if something went wrong.
                  Passwords are removed before it is written.
  --force         Run every step again on a machine that is already set up.
  --reinstall     The same as --force.

Data from an earlier install:
  The installer stops and asks what to do with it, unless you say:
  --reuse-data    Keep it.
  --wipe-data     Delete it and start fresh.
  --data-dir=DIR  Install into DIR and leave it alone.

Advanced settings (environment variables):
  TRACEBLOC_HOST_DATA_DIR     Where your data lives (default: ~/.tracebloc).
                              A local disk: network storage is refused.
  TRACEBLOC_HOST_DATASET_DIR  A separate folder for datasets (hostpath only)
  TRACEBLOC_STORAGE_MODE      node-local (default) or hostpath
  TRACEBLOC_NAMESPACE         Secure environment name (default: tracebloc)
  TRACEBLOC_CLUSTER_NAME      Cluster name (default: tracebloc)
  TRACEBLOC_HELM_VERSION      Helm release (default: v4.2.3)
  TRACEBLOC_SKIP_EXAMPLE      Set to 1 to skip the example use case.

Usage events:
  Each run reports one usage event: the step it reached, how long each
  step took, the exit code, an error class, your OS, architecture and
  the installer version. Never your arguments, paths, file names,
  username, hostname or credentials.
  TRACEBLOC_SKIP_TELEMETRY=1  Turn them off.
  TRACEBLOC_NO_TELEMETRY=1    Also turns them off (legacy name).
  DO_NOT_TRACK=1              Also turns them off.
  Any of them also turns off the usage events of tracebloc's services,
  and the hourly auto-upgrade keeps it that way. Every other log line
  stays in your secure environment either way.

Windows:
  irm https://tracebloc.io/i.ps1 | iex

Learn more: https://docs.tracebloc.io
HELP
  _tb_done=1   # an intended exit 0 under install_cleanup (tb_exit_rc)
  exit 0
}
