#!/usr/bin/env bash
# =============================================================================
#  progress.sh — what a wait shows: the live line, the progress-line gate and
#  the spinner helpers (spin, spin_cmd, spin_cmd_bounded). Sourced by install-k8s.sh.
# =============================================================================

# ── The live line ────────────────────────────────────────────────────────────
#  The one line that says what a wait is for. Animating (_tb_animate), a ticker
#  redraws it in place with a spinner and the time spent; plain prints no frame of
#  it, so the screen ends the same either way. tb_live_done TEXT ends it with
#  "  ✔ TEXT"; tb_live_done alone leaves a tb_live line as "  · MSG" (its wait had no
#  result line) and a tb_live_quiet one gone. While it runs, info/success/warn/hint
#  print below its "  · MSG" and above the ticker, and spin() waits inside it without
#  a line of its own. tb_live_next MSG goes on under a new name, the old one gone;
#  tb_live_stop ends it with no line (an error, the exit trap).
#  The live line belongs to the process that started it (_TB_LIVE_LEVEL, its
#  BASH_SUBSHELL, which bash 3.2 has): a subshell that inherits it, a $(…) above all,
#  leaves its ticker and the screen alone, and its lines go where its output goes.
#  Animating, it also shows what its downloads have brought in (_TB_DL_DIR, below).
_TB_LIVE_MSG=""; _TB_LIVE_QUIET=""; _TB_LIVE_DETAIL=""; _TB_LIVE_PID=""; _TB_LIVE_T0=0
_TB_LIVE_SHOWN=""; _TB_LIVE_LEVEL=0; _TB_DL_DIR=""
tb_live()       { _tb_live_begin "$1" ""; }
tb_live_quiet() { _tb_live_begin "$1" 1; }
_tb_live_begin() {
  tb_live_stop
  _TB_LIVE_MSG="$1"; _TB_LIVE_QUIET="$2"; _TB_LIVE_DETAIL=""; _TB_LIVE_T0=$SECONDS; _TB_LIVE_SHOWN=""
  _TB_LIVE_LEVEL="${BASH_SUBSHELL:-0}"
  if _tb_animate; then
    tb_scratch_dir _TB_DL_DIR tracebloc-live || _TB_DL_DIR=""
    _tb_tty tput civis 2>/dev/null || true
    _tb_live_tick
  fi
  return 0
}
# _tb_live_here -- this process started the live line it sees.
_tb_live_here() { [[ "${BASH_SUBSHELL:-0}" == "${_TB_LIVE_LEVEL:-0}" ]]; }
# tb_live_detail TEXT -- a count or the like after the message, animating only.
tb_live_detail() {
  [[ -n "$_TB_LIVE_MSG" && "$1" != "$_TB_LIVE_DETAIL" ]] || return 0
  _TB_LIVE_DETAIL="$1"
  if [[ -n "$_TB_LIVE_PID" ]] && _tb_live_here; then _tb_live_kill; _tb_live_tick; fi
  return 0
}
tb_live_done() {
  local msg="$_TB_LIVE_MSG" quiet="$_TB_LIVE_QUIET" shown="$_TB_LIVE_SHOWN"
  if [[ -n "$msg" ]]; then
    if _tb_live_here; then
      if _tb_animate; then
        _tb_live_kill
        _tb_tty printf '\r\033[K'
        _tb_tty tput cnorm 2>/dev/null || true
      fi
      _tb_dl_drop
      [[ -n "${1:-}" || -n "$quiet" || -n "$shown" ]] || printf '  · %s\n' "$msg"
    fi
    _TB_LIVE_MSG=""; _TB_LIVE_QUIET=""; _TB_LIVE_DETAIL=""; _TB_LIVE_SHOWN=""; _TB_LIVE_PID=""; _TB_DL_DIR=""
  fi
  [[ -z "${1:-}" ]] || success "$1"
  return 0
}
# tb_live_next MSG -- the wait goes on as MSG, when a live line runs: the old message
# leaves no line, as its result is the next one's. Nothing when none runs (a caller
# with no line of its own).
tb_live_next() {
  [[ -n "${_TB_LIVE_MSG:-}" ]] || return 0
  tb_live "$1"
}
tb_live_stop() {
  [[ -n "${_TB_LIVE_MSG:-}" ]] || return 0
  if _tb_live_here && _tb_animate; then
    _tb_live_kill
    _tb_tty printf '\r\033[K'; _tb_tty tput cnorm 2>/dev/null || true
  fi
  if _tb_live_here; then _tb_dl_drop; fi
  _TB_LIVE_MSG=""; _TB_LIVE_QUIET=""; _TB_LIVE_DETAIL=""; _TB_LIVE_SHOWN=""; _TB_LIVE_PID=""; _TB_DL_DIR=""
  return 0
}
# _tb_elapsed SECONDS -- "12s", "1m 05s".
_tb_elapsed() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if (( s < 60 )); then printf '%ss' "$s"; else printf '%sm %02ds' "$(( s / 60 ))" "$(( s % 60 ))"; fi
}
# The ticker: a background process that redraws the line until it is killed, or
# until the process it belongs to has gone: the installer, or a subshell that runs a
# live line of its own (a pipeline's reader, _example_lines). bash 3.2 has no
# BASHPID; the $(…) child execs sh, so sh's parent is this process. Its own errors
# are nobody's: no ERR trap, no errexit, and no stderr. _tb_live_kill stops it.
_tb_live_tick() {
  local msg="$_TB_LIVE_MSG" detail="$_TB_LIVE_DETAIL" t0="$_TB_LIVE_T0" dl="${_TB_DL_DIR:-}" parent=$$
  if (( ${BASH_SUBSHELL:-0} > 0 )); then parent="$(exec sh -c 'echo "$PPID"')"; fi
  (
    trap - ERR; set +e
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'); i=0; seen=""
    _TB_DL_TAIL=""; _TB_DL_RING=""; _TB_DL_PREV=0
    while kill -0 "$parent" 2>/dev/null; do
      # The downloads are read once a second once one has started, every tick until then.
      if [[ -n "$dl" ]] && { [[ "$SECONDS" != "$seen" ]] || (( ! ${_TB_DL_STARTED:-0} )); }; then seen=$SECONDS; _tb_dl_tick "$dl" "$SECONDS"; fi
      _tb_tty _tb_live_frame "${frames[i]}" "$msg" "$detail" "$(_tb_elapsed $(( SECONDS - t0 )))${_TB_DL_TAIL}"
      i=$(( (i + 1) % 10 ))
      sleep 0.12
    done
  ) 2>/dev/null &
  _TB_LIVE_PID=$!
}
# _tb_live_frame GLYPH MSG DETAIL TIME -- one frame of the live line: the spinner's
# GLYPH, MSG, DETAIL when there is one, then TIME (the time spent and what the
# downloads brought in).
_tb_live_frame() {
  printf "\r\033[K  ${CYAN}%s${RESET} %s${3:+  %s}  ${DIM}%s${RESET}" "$1" "$2" ${3:+"$3"} "$4"
}
# SIGKILL, never TERM: until the ticker has reset the traps it inherited, a TERM runs
# the installer's TERM and EXIT traps inside it (install_cleanup, mid-install), or is
# lost and leaves the wait below hung (bash 5.2). No trap can catch a KILL.
_tb_live_kill() {
  [[ -n "${_TB_LIVE_PID:-}" ]] || return 0
  kill -KILL "$_TB_LIVE_PID" 2>/dev/null || true
  wait "$_TB_LIVE_PID" 2>/dev/null || true
  _TB_LIVE_PID=""
}
# Around a line printed while the live line runs: off, its "  · MSG" kept above the
# first such line, then on again below it. Only where the line was started; plain,
# there is no ticker to stop, and the "  · MSG" goes above the line all the same.
_tb_live_hold() {
  [[ -n "${_TB_LIVE_MSG:-}" ]] && _tb_live_here || return 0
  if [[ -n "${_TB_LIVE_PID:-}" ]]; then
    _tb_live_kill
    _tb_tty printf '\r\033[K'
  fi
  if [[ -z "$_TB_LIVE_QUIET" && -z "$_TB_LIVE_SHOWN" ]]; then
    printf '  · %s\n' "$_TB_LIVE_MSG"
    _TB_LIVE_SHOWN=1
  fi
}
_tb_live_resume() {
  [[ -n "${_TB_LIVE_MSG:-}" && -z "${_TB_LIVE_PID:-}" ]] && _tb_live_here || return 0
  _tb_animate || return 0
  _tb_live_tick
}

# ── Progress-line gate — animate only where a redraw reads ──
# A spinner redraws its line with \r, \033[K and tput. Where colour is off
# (NO_COLOR / not a TTY / TERM=dumb / TRACEBLOC_PLAIN=1, decided once above as
# _tb_mode=none) those bytes land in a log as frame after frame of garbage, so
# every in-place progress line goes through these four helpers: animating, they
# draw and clear as before; plain, _tb_progress_start prints the message ONCE as a
# static line (the Go CLI's `  · msg` form) and the rest print nothing.
_tb_animate() { [[ "${_tb_mode:-none}" != "none" ]]; }
# _tb_tty CMD... -- run CMD with its stdout on the terminal itself. After setup_log_file
# stdout is tee'd into the install log, and animation frames must never reach it: a
# frame glued to the next line hides helm's error. Fixed fd 7: bash 3.2 has no {var}>.
_tb_tty() {
  if [[ -n "${_TB_TTY_FD:-}" ]]; then
    "$@" >&7
  else
    "$@"
  fi
}
# _tb_progress_start MSG — hide the cursor (animating) or print MSG once (plain).
_tb_progress_start() {
  if _tb_animate; then
    _tb_tty tput civis 2>/dev/null || true
  else
    printf '  · %s\n' "$1"
  fi
}
# _tb_progress_frame GLYPH MSG [SECONDS] — draw one frame in place, with the time
# spent when given; nothing when plain.
_tb_progress_frame() {
  _tb_animate || return 0
  if [[ -n "${3:-}" ]]; then
    _tb_tty printf "\r\033[K  ${CYAN}%s${RESET} %s  ${DIM}%s${RESET}" "$1" "$2" "$(_tb_elapsed "$3")"
  else
    _tb_tty printf "\r  ${CYAN}%s${RESET} %s" "$1" "$2"
  fi
}
# _tb_progress_clear — wipe the line in place (more output follows); nothing when plain.
_tb_progress_clear() {
  _tb_animate || return 0
  _tb_tty printf "\r\033[K"
}
# _tb_progress_end — wipe the line and restore the cursor; nothing when plain.
_tb_progress_end() {
  _tb_animate || return 0
  _tb_tty printf "\r\033[K"
  _tb_tty tput cnorm 2>/dev/null || true
}

# _tb_proc_tree PID — PID and every descendant, one per line, parents first.
# Captured BEFORE any signal: once a wrapper dies its children reparent to init
# and `pgrep -P` can no longer see them.
_tb_proc_tree() {
  local _todo="$1" _next _p
  while [[ -n "$_todo" ]]; do
    _next=""
    for _p in $_todo; do
      echo "$_p"
      _next="$_next $(pgrep -P "$_p" 2>/dev/null || true)"
    done
    # shellcheck disable=SC2086  # word-splitting the pid list is the point
    _todo="$(printf '%s\n' $_next)"
  done
}

# _tb_proc_alive PID COMM — true while PID is a live (non-zombie) process still
# named COMM. `ps`, not `kill -0`: kill -0 on a root-owned `dnf` from a non-root
# installer fails with EPERM and would read a running process as gone. The
# name check means a pid the kernel reused is never taken for, or killed as,
# the process we captured.
_tb_proc_alive() {
  local _st="" _c=""
  read -r _st _c < <(ps -o stat= -o comm= -p "$1" 2>/dev/null || true) || true
  _c="${_c##*/}"; _c="${_c// /}"   # as _tb_spin_reap captured it: macOS prints a path, maybe with spaces
  [[ -n "$_st" && "$_st" != Z* && "$_c" == "$2" ]]
}

# _tb_spin_reap PID [GRACE_S] — spin's deadline path. TERM to PID and every
# descendant, wait up to GRACE_S whole seconds for all of them to exit, then
# KILL only those still alive under the same name. Empty GRACE_S is the
# historical 0.5 s, right for kubectl, curl and systemctl probes. A package manager
# is not one of those: rpm and dpkg defer TERM until the transaction is
# written, and a KILL 0.5 s later lands mid-transaction.
# Through sudo, sudo relays the TERM and only the reap of the WHOLE tree keeps
# its child from being orphaned holding the lock. Sets _TB_SPIN_SURVIVORS to
# "pid:name …" for whatever is still alive after the KILL (a root-owned
# process a non-root installer may not KILL), so the caller can name it.
_TB_SPIN_SURVIVORS=""
_tb_spin_reap() {
  local _pid="$1" _grace="${2:-}" _tree _p _c _pairs="" _pair _live _ticks=0 _t0=$SECONDS
  _TB_SPIN_SURVIVORS=""
  # A typo'd TB_PM_KILL_GRACE must not fall back to 0.5 s for a package
  # manager, nor abort the deadline path in $(( )): anything but digits is 60.
  if [[ -n "$_grace" ]]; then
    [[ "$_grace" =~ ^[0-9]+$ ]] && _grace=$(( 10#$_grace )) || _grace=60
  fi
  _tree="$(_tb_proc_tree "$_pid")"
  for _p in $_tree; do
    _c="$(ps -o comm= -p "$_p" 2>/dev/null || true)"
    _c="${_c##*/}"; _c="${_c// /}"
    [[ -n "$_c" ]] && _pairs="$_pairs $_p:$_c"
  done
  for _p in $_tree; do
    kill -TERM "$_p" 2>/dev/null || true
  done
  if [[ -z "$_grace" ]]; then
    sleep 0.5
  else
    # Ticks AND the wall clock, as spin's own deadline: a slow host stretches
    # every sleep, and the grace must not stretch with it.
    while (( _ticks * 2 < _grace * 10 && SECONDS - _t0 <= _grace )); do
      _live=0
      for _pair in $_pairs; do
        _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && { _live=1; break; }
      done
      (( _live )) || break
      sleep 0.2
      _ticks=$(( _ticks + 1 ))
    done
  fi
  for _pair in $_pairs; do
    _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && { kill -9 "${_pair%%:*}" 2>/dev/null || true; }
  done
  sleep 0.1
  for _pair in $_pairs; do
    [[ "${_pair%%:*}" == "$_pid" ]] && continue   # our own child: wait reaps it
    _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && _TB_SPIN_SURVIVORS="${_TB_SPIN_SURVIVORS:+$_TB_SPIN_SURVIVORS }$_pair"
  done
  return 0
}

# ── Spinner — hides noisy command output behind an animated status line ──────
#  Usage:  spin <pid> "Installing foo…" [deadline_seconds]
#  Animates only through the progress-line gate above: with colour off it prints
#  "  · Installing foo…" once and no frame, \r or escape.
#  The background process's stdout/stderr should already be redirected to a file
#  before calling spin. spin waits for the PID to exit and returns its exit code.
#  With the optional third argument, a still-running PID is killed once the
#  deadline passes and spin returns 124 (GNU timeout's convention) — the
#  backstop for commands that can wedge indefinitely. The optional
#  fourth is the TERM-to-KILL grace in whole seconds (_tb_spin_reap below);
#  empty keeps the 0.5 s every non-package-manager caller has always had.
#  _TB_SPIN_QUIET=1 prints no static line when plain (the copy has none for this
#  wait), and inside a live line (tb_live) spin draws nothing: the live line is it.
spin() {
  local pid="$1" msg="$2" deadline_s="${3:-}" grace_s="${4:-}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local ticks=0                           # one tick ≈ 0.12s
  local _spin_t0=$SECONDS                 # the deadline's wall clock: ticks alone stretch on a slow host
  local own=1
  [[ -z "${_TB_LIVE_MSG:-}" ]] || own=""

  if [[ -n "$own" ]]; then
    if _tb_animate || [[ -z "${_TB_SPIN_QUIET:-}" ]]; then
      _tb_progress_start "$msg"           # hide cursor, or the one static line
    fi
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$deadline_s" ]] && (( ticks * 12 >= deadline_s * 100 || SECONDS - _spin_t0 > deadline_s )); then
      # The whole tree, not just the pid: it is often a wrapper subshell
      # (spin_cmd_bounded's `tb_root dnf …`), and
      # signalling only the wrapper orphans the real worker.
      # Every line is failure-proofed (`|| true`): under `set -e` a bare
      # failure would abort the deadline path before `return 124`, and the
      # caller would never see the timeout.
      _tb_spin_reap "$pid" "$grace_s" || true
      wait "$pid" 2>/dev/null || true
      [[ -z "$own" ]] || _tb_progress_end
      return 124
    fi
    [[ -z "$own" ]] || _tb_progress_frame "${frames[i]}" "$msg" "$(( SECONDS - _spin_t0 ))"
    i=$(( (i + 1) % ${#frames[@]} ))
    ticks=$(( ticks + 1 ))
    sleep 0.12
  done

  wait "$pid"
  local rc=$?
  [[ -z "$own" ]] || _tb_progress_end     # clear the spinner line, restore cursor
  return $rc
}

# ── Convenience wrapper: run a command quietly behind a spinner ───────────────
#  Usage:  spin_cmd "Installing foo…" apt-get install -y foo
#  stdout/stderr are captured in the LOG_FILE (if set) or a private mktemp file
#  (_tb_spin_logfile; never a fixed /tmp name)
spin_cmd() {
  local msg="$1"; shift
  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  if ! spin "$pid" "$msg"; then
    _tb_live_hold
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    _tb_live_resume
    return 1
  fi
}

# ── spin_cmd with a hard deadline ─────────────────────────────────────
#  Usage:  spin_cmd_bounded <seconds> "Doing the thing…" cmd args…
#  For commands that can wedge indefinitely against a stuck endpoint (helm
#  talking to a wedged kube-apiserver). Same quiet-log capture + failure tail
#  as spin_cmd; returns the command's real exit code, or 124 when the deadline
#  killed it (with a timeout note so the user knows it was us, not the tool).
#  `--grace N` first: N whole seconds between TERM and KILL instead of 0.5 —
#  for a package manager, which must be let finish its transaction
#  (callers pass "${TB_PM_KILL_GRACE:-60}"). Whatever is still
#  running after it is named, so the user knows a lock may still be held.
spin_cmd_bounded() {
  local grace=""
  if [[ "${1:-}" == "--grace" ]]; then grace="${2:-}"; shift 2; fi
  local secs="$1" msg="$2"; shift 2
  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  local rc=0 _sv
  spin "$pid" "$msg" "$secs" "$grace" || rc=$?
  (( rc == 0 )) || _tb_live_hold
  if (( rc == 124 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg} — timed out after ${secs}s${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    for _sv in ${_TB_SPIN_SURVIVORS:-}; do
      echo -e "  ${YELLOW}⚠ ${_sv#*:} (PID ${_sv%%:*}) is still running and may hold the package manager's lock — wait for it to exit (ps -p ${_sv%%:*}) before running the installer again.${RESET}" >&2
    done
    _tb_live_resume
    return 124
  elif (( rc != 0 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    _tb_live_resume
    return $rc
  fi
}

# _tb_spin_logfile — sets _TB_SPIN_LOG to where the spinner helpers append a
# command's output: LOG_FILE once setup_log_file has run (every real install
# path), else a private mktemp file made once per shell. The old fallback was a
# fixed /tmp/tracebloc-spin.log appended with `>>`, which follows a planted
# symlink the same way. /dev/null only if mktemp itself fails.
_tb_spin_logfile() {
  if [[ -n "${LOG_FILE:-}" ]]; then _TB_SPIN_LOG="$LOG_FILE"; return 0; fi
  [[ -n "${_TB_SPIN_LOG:-}" && -f "$_TB_SPIN_LOG" ]] && return 0
  _TB_SPIN_LOG="$(mktemp "${TMPDIR:-/tmp}/tracebloc-spin-XXXXXX" 2>/dev/null)" || _TB_SPIN_LOG=""
  [[ -n "$_TB_SPIN_LOG" ]] || _TB_SPIN_LOG=/dev/null
  return 0
}
