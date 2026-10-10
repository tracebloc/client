#!/usr/bin/env bash
# =============================================================================
#  exit-trap.sh — an EXIT trap that cannot turn an abort into exit 0
#  (client-dev#1754, found in install.sh by client-dev#1751).
# -----------------------------------------------------------------------------
#  macOS ships /bin/bash 3.2. Under `set -u` there, an unbound variable aborts
#  the script, the EXIT trap runs, and the process exits 0 — bash 5 exits 1. The
#  trap cannot tell from `$?` either: inside it, `$?` is the last COMPLETED
#  command's status, so `trap 'rc=$?; cleanup; exit $rc' EXIT` faithfully
#  returns that 0. A test harness built that way reports green on a run that
#  died half-way, which is the one thing a harness must never do.
#
#  The fix is a sentinel only a deliberate exit sets. This file wraps `exit` as
#  a function that sets it and then calls the builtin, and the trap's handler
#  turns a 0 into 1 when the sentinel is unset. So:
#
#    exit N            -> N, whatever N is (cleanup runs first)
#    an abort          -> never called `exit`: a 0 becomes 1, a non-zero stays
#    falling off the end -> treated as an abort: END EVERY SCRIPT WITH `exit 0`
#
#  The last line is the price, and it is deliberate: on 3.2 a script that ran to
#  the end and one that aborted look the same to the trap, so only an explicit
#  `exit` can say "this finished".
#
#  USAGE — source it, then install the trap instead of writing `trap … EXIT`:
#
#    . "$ROOT/scripts/lib/exit-trap.sh"
#    TMP=$(mktemp -d); tb_exit_trap 'rm -rf "$TMP"' INT TERM HUP
#    …
#    exit 0
#
#  The first argument is the cleanup, eval'd once on the way out (quote it the
#  way you would quote a trap body); the rest are extra signals the same handler
#  takes. A failing cleanup never changes the exit status.
#
#  scripts/tests/exit-traps.sh holds every EXIT trap under scripts/ to this
#  helper (or to the same sentinel written inline), and reads the helper's
#  names from this file — keep the installer, the handler and the `=0`
#  sentinel assignment recognisable.
#
#  bash 3.2 and 5: no declare -A, no mapfile, no ${x,,}. In POSIX mode a
#  function cannot shadow `exit`; every exit there is then an abort, which
#  fails closed.
# =============================================================================

_tb_done=0
_tb_cleanup=''
_tb_signals=''

# shellcheck disable=SC2120  # `exit` with no argument keeps the last status, as the builtin does
exit() {
  local _tb_rc=${1-$?}
  _tb_done=1
  builtin exit "$_tb_rc"
}

tb_exit_trap() {
  _tb_done=0
  _tb_cleanup=$1
  shift
  _tb_signals="$*"
  trap '_tb_on_exit' EXIT "$@"
}

_tb_on_exit() {
  local _tb_rc=$?
  # shellcheck disable=SC2086  # the signal list is word-split on purpose
  trap - EXIT $_tb_signals
  eval "$_tb_cleanup" || :
  if [ "$_tb_rc" -eq 0 ] && [ "$_tb_done" != 1 ]; then
    echo "exit-trap: ${0##*/} ended without a deliberate exit (an abort, or a missing 'exit 0' at the end) -- exiting 1" >&2
    _tb_rc=1
  fi
  builtin exit "$_tb_rc"
}
