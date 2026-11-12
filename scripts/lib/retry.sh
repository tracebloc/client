#!/usr/bin/env bash
# =============================================================================
#  retry.sh — run a command under a deadline (_bounded, _bounded_capture,
#  _bounded_root) and again on failure (retry), and read a minutes override
#  (tb_minutes_or). Sourced by install-k8s.sh.
# =============================================================================

# _bounded SECONDS CMD… — run CMD with a deadline, so a wedged external call can't
# hang a headless install (installer rule: every kubectl/helm/systemctl probe must be
# bounded). Returns CMD's exit status, or 124 when the deadline fired. Output is
# NOT redirected — the caller decides — and stdin reaches CMD.
#
# timeout(1)/gtimeout(1) when either is present: they signal the whole process
# group. Neither ships on a stock Mac, and the bare call this used to fall back to
# was no bound at all there, so without them the deadline
# comes from _tb_bounded_bg, the background-PID mechanism _bounded_capture uses.
_bounded() {
  local t="$1"; shift
  if   has timeout;  then timeout  "$t" "$@"
  elif has gtimeout; then gtimeout "$t" "$@"
  else _tb_bounded_bg "$t" "$@"; fi
}

# _tb_bounded_bg SECONDS CMD… — the deadline with no coreutils: run CMD in the
# background, stdin preserved (`<&0`; a background job in a non-interactive shell
# otherwise reads /dev/null), and poll it. On the deadline: TERM, then KILL, and
# return 124; otherwise CMD's own status. Only CMD itself is signalled, not a
# process group (job control is off in the installer's shell). SECONDS reads as
# timeout(1) reads it: a number with an optional s/m/h/d suffix (a fraction rounds
# UP, so the bound is never shorter than asked), 0 disables the deadline, and
# anything else is timeout(1)'s 125, "the interval is invalid".
#
# The poll tick is 0.1s where `sleep` accepts fractions and 1s otherwise, detected
# once per shell — a 1-second floor would charge a full second for every call that
# answered instantly.
_tb_bounded_bg() {
  local asked="$1" raw="$1" mult=1 secs; shift
  case "$raw" in
    *s) raw="${raw%s}" ;;
    *m) raw="${raw%m}"; mult=60 ;;
    *h) raw="${raw%h}"; mult=3600 ;;
    *d) raw="${raw%d}"; mult=86400 ;;
  esac
  case "$raw" in
    ''|*[!0-9.]*|*.*.*|.*) echo "_bounded: invalid time interval '${asked}'" >&2; return 125 ;;
    *.*) raw=$(( 10#${raw%%.*} + 1 )) ;;
  esac
  secs=$(( 10#$raw * mult ))
  if [ "$secs" -eq 0 ]; then "$@"; return; fi
  # Poll granularity, detected ONCE per shell and cached: a fast call must not cost
  # a whole tick. GNU and BSD/macOS `sleep` both take fractions; a strictly POSIX
  # one does not, so fall back to 1s rather than spin or fail.
  if [ -z "${_TB_CAPTURE_TICK:-}" ]; then
    if sleep 0.1 2>/dev/null; then _TB_CAPTURE_TICK=0.1; _TB_CAPTURE_PER_SEC=10
    else                           _TB_CAPTURE_TICK=1;   _TB_CAPTURE_PER_SEC=1; fi
  fi
  "$@" <&0 &
  # The waiter's OWN stderr is silenced, never CMD's: a job killed on the deadline
  # is reaped asynchronously, and bash then prints "PID Terminated: 15 CMD" at its
  # next command -- inside the loop, outside `wait`'s redirection. Measured on
  # /bin/bash 3.2; it would land on the user's terminal, or in a --diagnose file.
  _tb_bounded_wait "$!" "$secs" 2>/dev/null
}

# _tb_bounded_wait PID SECONDS -- _tb_bounded_bg's deadline loop over a background
# job of this shell: its status, or 124 once SECONDS have passed.
#
# TWO CLOCKS, and the deadline is whichever runs out first. The tick count is never
# early (each tick sleeps at least one tick), but it is not a bound: every tick also
# pays a `kill -0` and a `sleep` fork, and on a loaded macOS runner "1s, then a 2s
# grace" measured 6.6s. The wall clock caps it. $SECONDS is whole
# seconds, so a difference of N means MORE than N-1 have passed: the deadline needs
# `> secs` to stay never-shorter-than-asked; the grace is best-effort and takes `>= 2`.
_tb_bounded_wait() {
  local pid="$1" rc=0 waited=0 t0=$SECONDS
  local limit=$(( $2 * _TB_CAPTURE_PER_SEC ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ] || [ $(( SECONDS - t0 )) -gt "$2" ]; then
      # EVERY LINE FAILURE-PROOFED (`|| true`), exactly as spin's deadline path is
      # and for the reason recorded there: `wait` on a TERM'd child reports 143 and `kill` fails outright
      # on an already-exited pid, so under `set -e` either aborted this arm BEFORE
      # `return 124` and the caller saw a fired deadline as "the command failed
      # with 143". That is the stall/failure conflation every caller keys on.
      # Measured: bash -c 'set -e; source retry.sh; _bounded_capture 1 f sleep 30'
      # -> 143 (Not reproducible through `( set -e; … ) || rc=$?` — bash inherits
      # the AND-OR errexit suppression into subshells, which is why the first draft
      # of the guard passed against this bug.)
      kill -TERM "$pid" 2>/dev/null || true
      # ESCALATE IN-LINE, not from a detached subshell that races `wait`: a child
      # ignoring TERM otherwise decides how long the installer waits, and a KILL
      # arriving after `wait` has reaped the child can signal a REUSED pid. While
      # the child is still our own unreaped child its pid cannot be recycled, so
      # escalating here is both bounded and safe.
      local _kwait=0 _klimit=$(( 2 * _TB_CAPTURE_PER_SEC )) _kt0=$SECONDS
      while kill -0 "$pid" 2>/dev/null && [ "$_kwait" -lt "$_klimit" ] && [ $(( SECONDS - _kt0 )) -lt 2 ]; do
        sleep "$_TB_CAPTURE_TICK" || true
        _kwait=$(( _kwait + 1 ))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$_TB_CAPTURE_TICK"
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# _bounded_capture SECONDS OUTFILE CMD… — run CMD with stdout+stderr captured to
# OUTFILE, bounded on EVERY platform. Returns CMD's status, or 124 when the
# deadline fired. THREE OUTCOMES, all distinguishable by the caller: 0 (answered),
# 124 (did not answer in time), anything else (CMD's own failure).
#
# WHY IT EXISTS ALONGSIDE _bounded. `_bounded` leaves the output where
# the caller put it; this one captures it to a FILE, and uses the background-PID
# deadline (_tb_bounded_bg) on every host, coreutils or not, so a capture behaves
# the same everywhere.
#
# The --diagnose bundle is a read whose output is the point, and the one where the
# cost is the whole artifact rather than a stall: every read in it goes into a `{ … } > file`
# group, so ONE call that never returns means no file at all, from the one run
# collected BECAUSE the machine is already broken. A liveness gate passing in 5s
# does not make a slower read of the same daemon safe: more work, a different
# budget.
#
# The mechanism is _tb_bounded_bg's: the same background-PID + kill as spin,
# no coreutils, TERM first and then KILL, so a well-behaved child can clean up.
_bounded_capture() {
  local secs="$1" out="$2"; shift 2
  : > "$out" 2>/dev/null || return 2      # cannot capture => "could not tell", not "empty"
  # stdin from /dev/null, as a plain background job had it: a --diagnose read never
  # takes input, and must not sit on the terminal's.
  _tb_bounded_bg "$secs" "$@" >"$out" 2>&1 </dev/null
}

# _bounded_root SECONDS CMD… — like _bounded, but for a command that runs as root.
# `_bounded` execs `timeout`, a BINARY, which resolves `sudo` from PATH and so
# bypasses the root-aware `sudo()` shadow below — and as root (the normal
# `--prepare-host` path, where a least-privilege install often has no sudo binary at all)
# `timeout sudo CMD` then fails to find sudo and the caller misreads a live daemon
# as dead. So the bound goes INSIDE the executor: `tb_root timeout
# SECS CMD` runs bare as root and through the real sudo otherwise, and under
# --print a read stays a read (`timeout` is on _tb_root_reads' list).
_bounded_root() {
  local t="$1"; shift
  if   has timeout;  then tb_root timeout  "$t" "$@"
  elif has gtimeout; then tb_root gtimeout "$t" "$@"
  else tb_root_bounded "$t" "$@"; fi   # a binary under the deadline, never the tb_root function (a killed subshell leaves CMD running)
}

# Sanitize a minutes-valued env override to a base-10 integer, else <default>.
# The 10# base prefix matters: bash arithmetic reads a leading zero as octal,
# so 08/09 would ABORT $(( … )) under set -e (mid-create, leaving a partial
# cluster) and 010 would silently become 8.
tb_minutes_or() {
  local v="$1" def="$2"
  case "$v" in ''|*[!0-9]*) echo "$def"; return 0 ;; esac
  echo $((10#$v))
}

# ── Retry wrapper for flaky network calls ────────────────────────────────────
#  Usage:  retry 3 5 curl -fsSL https://example.com -o /tmp/file
#          retry <max_attempts> <delay_seconds> <command...>
retry() {
  local max_attempts="$1" delay="$2"; shift 2
  local attempt=1
  while true; do
    if "$@"; then return 0; fi
    if [[ $attempt -ge $max_attempts ]]; then
      warn "Command failed after $max_attempts attempts: $*"
      return 1
    fi
    warn "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 2))  # a short outage outlasts a fixed delay; double it, like install.sh's fetch
    ((attempt++))
  done
}
