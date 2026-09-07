#!/usr/bin/env bats
# =============================================================================
#  e2e-cleanup-trap.bats — every k3d e2e harness must reap its cluster through a
#  BOUNDED, LOUD cleanup that cannot change the harness's verdict.
#
#  WHY THIS EXISTS (client#979). All seven harnesses carried the identical line:
#
#      cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
#      trap cleanup EXIT
#
#  and it produced a reviewer-visible FALSE SIGNAL on client#977, a test-only
#  diff: `E2E mysql 8.4 (ubuntu-24.04-arm)` reported `cancelled` on a PR that
#  changed three files under scripts/tests/ and nothing e2e-mysql.sh reads.
#  From the job log — 09:09:07 start, 09:15:44 a correct `set -e` abort on a
#  rollout `--timeout=300s`, then NO OUTPUT AT ALL until 09:39:23 when the job's
#  own `timeout-minutes: 30` killed it. "Terminate orphan process: pid (4358)
#  (k3d)" is the hung child. ~24 minutes, all of it inside the EXIT TRAP.
#
#  READ THE MECHANISM CAREFULLY, because a fix aimed at the body is aimed at the
#  wrong line: `set -e` WORKED. The script aborted, on time, with a named reason.
#  What was lost is the VERDICT — GitHub's `cancelled` is neither pass nor fail,
#  and a genuine mysql regression would arrive wearing the same costume
#  (backend#1758: "a job timeout destroys the verdict artifact"; client#753 /
#  client#920 are the same class at other sites).
#
#  THREE PROPERTIES, and fixing fewer than three leaves the failure mode intact:
#    1. BOUNDED — `k3d cluster delete` talks to the Docker engine and, unlike
#       `k3d cluster start`/`create`, accepts no `--timeout` of its own.
#    2. NOT SILENCED — `>/dev/null 2>&1` is what made 24 minutes invisible; there
#       was no line to attribute the stall to, so it read as "the test hung".
#    3. VERDICT-PRESERVING — errexit is LIVE inside an EXIT trap, so any command
#       there ending non-zero aborts the trap and OVERWRITES the exit status.
#       Verified: `exit 7` plus a trap whose last command is `false` exits 1.
#
#  THE LIST IS DERIVED FROM THE TREE, not enumerated, so an eighth harness
#  inherits all three. That is the whole lesson of client#963, where a harness
#  drifted out of a hand-written list and the guard went quiet about it; the
#  sibling e2e-metrics-apiservice-wait.bats records the same lesson next to the
#  enumeration it still has to maintain (it legitimately excludes harnesses that
#  render no preflight — there is no such exclusion here, every k3d harness has a
#  cluster to reap).
#
#  Pure text/structure assertions — no cluster, no Docker, no network.
# =============================================================================

setup() {
  TESTS_DIR="$BATS_TEST_DIRNAME"
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COMMON="$TESTS_DIR/lib/e2e-common.sh"
  # At least this many harnesses must be found. THE CENSUS (backend#2849's house
  # rule): a glob that matches nothing passes every "all of them are clean" loop
  # in this file silently, so the count is asserted separately. A floor, raised
  # deliberately when a harness lands — never lowered to make this green.
  HARNESS_FLOOR=7
}

# ── the derivation ───────────────────────────────────────────────────────────
# Every scripts/tests/e2e-*.sh that brings up a cluster via the installer's own
# create_cluster. Derived twice over: from the glob, and from the call — so a new
# harness is in scope the moment it creates a cluster, with nothing to remember.
_harnesses() {
  local dir="${1:-$TESTS_DIR}" f
  for f in "$dir"/e2e-*.sh; do
    [ -f "$f" ] || continue
    grep -qE '(^|[^[:alnum:]_])create_cluster([^[:alnum:]_]|$)' "$f" || continue
    printf '%s\n' "$f"
  done
}

# The body of a file's `cleanup()` function, brace to brace.
#
# BOTH SPELLINGS. The pre-fix shape was a ONE-LINER — `cleanup() { …; }` — which
# has no `^}` line to stop on, so a naive "print until ^}" swallows the rest of
# the file and every downstream check then measures the whole harness instead of
# its cleanup. Caught by driving this against the pre-fix tree; the self-test
# below pins it, because an over-reading extractor is exactly the "reports
# coverage it cannot provide" failure this file exists to prevent.
_cleanup_body() {
  awk '
    /^cleanup\(\)[[:space:]]*\{/ { print; if ($0 ~ /\}[[:space:]]*$/) exit; f=1; next }
    f                            { print; if ($0 ~ /^\}/) exit }
  ' "$1"
}

# ── the per-harness checks, ONE implementation ───────────────────────────────
# Each prints the reason on failure and returns non-zero. The not-vacuous
# self-tests at the bottom drive these SAME functions against planted fixtures,
# so what CI trusts is what was proven to fire.

# No harness may spell the delete itself — it must go through the shared,
# bounded e2e_cleanup_cluster, or the bound is one copy-paste from being lost.
_check_no_direct_delete() {
  local f="$1"
  if grep -nE 'k3d[[:space:]]+cluster[[:space:]]+delete' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
    echo "$f spells 'k3d cluster delete' directly — route it through e2e_cleanup_cluster (e2e-common.sh) so the bound, the logging and the exit-status discipline cannot be lost per-copy (client#979):"
    grep -nE 'k3d[[:space:]]+cluster[[:space:]]+delete' "$f" | grep -vE '^[0-9]+:[[:space:]]*#'
    return 1
  fi
}

_check_traps_cleanup() {
  local f="$1"
  grep -qE '^trap[[:space:]]+cleanup[[:space:]]+EXIT' "$f" || {
    echo "$f has no 'trap cleanup EXIT' — its cluster is never reaped"
    return 1
  }
}

_check_cleanup_calls_shared_reap() {
  local f="$1" body
  body="$(_cleanup_body "$f")"
  [ -n "$body" ] || { echo "$f has no cleanup() function to inspect"; return 1; }
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*e2e_cleanup_cluster([[:space:]]|$)' || {
    echo "$f's cleanup() does not call e2e_cleanup_cluster — the cluster reap is unbounded or absent (client#979)"
    return 1
  }
}

# THE CLASS, not the instance. `k3d cluster delete` is not the only thing in these
# traps that talks to the Docker engine — e2e-proxy.sh also reaped a squid
# container with an equally unbounded, equally silenced `docker rm -f`, a second
# route to the same stall in the same trap. Any docker/k3d invocation inside a
# cleanup must carry a deadline; the shared reap satisfies this for the cluster.
_check_cleanup_engine_calls_bounded() {
  local f="$1" body offenders
  body="$(_cleanup_body "$f")"
  [ -n "$body" ] || { echo "$f has no cleanup() function to inspect"; return 1; }
  offenders="$(printf '%s\n' "$body" \
    | grep -vE '^[[:space:]]*#' \
    | grep -E '(^|[|;&(]|[[:space:]])(docker|k3d)[[:space:]]' \
    | grep -vE '_bounded[[:space:]]+"[^"]*"[[:space:]]+(docker|k3d)[[:space:]]' || true)"
  [ -z "$offenders" ] || {
    echo "$f's cleanup() calls the Docker engine with no deadline — a wedged engine blocks it exactly like the k3d delete did (client#979):"
    printf '%s\n' "$offenders"
    return 1
  }
}

# How many engine calls the check above actually inspected, across one file.
_count_cleanup_engine_calls() {
  _cleanup_body "$1" \
    | grep -vE '^[[:space:]]*#' \
    | grep -cE '(^|[|;&(]|[[:space:]])(docker|k3d)[[:space:]]' || true
}

# The body of a named top-level function in e2e-common.sh, brace to brace.
_helper_body() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\)" { print; if ($0 ~ /\}[[:space:]]*$/) exit; f = 1; next }
    f                    { print; if ($0 ~ /^\}/) exit }
  ' "$COMMON"
}

# Lines in a helper that actually INVOKE the engine.
#
# NOT a bare grep for `docker|k3d`, which is what the cleanup-body checker can
# afford to be. These helpers are the loud ones — their whole job is to print
# lines like `'k3d cluster delete X' TIMED OUT after 120s` — so a bare grep
# reports every message ABOUT the engine as a call TO it. Written that way first
# and it was red on a clean tree, then a mutation that removed a real `_bounded`
# "fired" on those echoes rather than on the mutation: a check that is already
# failing cannot tell you anything, which is this repo's dominant defect class
# wearing the opposite face. So: drop echo/printf statements, blank out quoted
# spans, and only then look for a command.
_helper_engine_lines() {
  _helper_body "$1" \
    | grep -vE '^[[:space:]]*#' \
    | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
    | awk '
        BEGIN { q = sprintf("%c", 39); sq = q "[^" q "]*" q
                eng = "(^|[|;&(]|[[:space:]])(docker|k3d)[[:space:]]" }
        { orig = $0; d = $0
          gsub(/"[^"]*"/, "", d); gsub(sq, "", d)
          if (d ~ eng) print orig }'
}

# THE SAME RULE, one level down. Both reaps now live in e2e-common.sh, so that is
# where "every docker/k3d call carries a deadline" has to be enforced — a helper
# that dropped its `_bounded` would silently un-bound all seven traps at once,
# which is a worse version of the copy-paste drift the extraction removed.
# `docker inspect` counts: an existence probe against a wedged engine hangs
# exactly like the removal it precedes.
_check_helper_engine_calls_bounded() {
  local fn="$1" body offenders
  body="$(_helper_body "$fn")"
  [ -n "$body" ] || { echo "$COMMON has no ${fn}() body to inspect"; return 1; }
  # Whitelist matched on the ORIGINAL text, so the `"$secs"` deadline argument is
  # still there to be seen (the detection above works on a de-quoted copy).
  offenders="$(_helper_engine_lines "$fn" \
    | grep -vE '_bounded[[:space:]]+"[^"]*"[[:space:]]+(docker|k3d)[[:space:]]' || true)"
  [ -z "$offenders" ] || {
    echo "${fn}() in $COMMON calls the Docker engine with no deadline — every harness trap delegates to this one copy, so an unbounded call here re-creates the client#979 stall in all of them at once:"
    printf '%s\n' "$offenders"
    return 1
  }
}

# How many engine calls the helper check actually inspected. Same extraction, so
# the census counts exactly what the check examined and cannot drift from it.
_count_helper_engine_calls() {
  _helper_engine_lines "$1" | grep -c . || true
}

# NO STATEMENT IN A CLEANUP MAY BE ABLE TO END NON-ZERO. This is the rule the
# `local _status=$?` / `return "$_status"` pair depends on, and the one
# e2e-full-seal.sh broke: errexit is LIVE inside an EXIT trap, so a command that
# fails ABORTS the trap — skipping both the `return` and everything after it.
#
# The shape that hid it: `[ -n "$CREDS_FILE" ] && rm -f "$CREDS_FILE"`. There is a
# standing note in this repo that `A && B` mid-script does not abort under set -e,
# and it does NOT apply here — the exemption covers every command in a `&&`/`||`
# list EXCEPT THE LAST, and `rm` is last, so it is fully subject to errexit. A
# failing `rm -f` (read-only mount, mode-500 parent) cost the verdict AND leaked
# the cluster, because e2e_cleanup_cluster never ran (LukasWodka + saqlainsyed007,
# both driven).
#
# So every statement must be terminated by `|| true` / `|| :` / `|| echo …`, or be
# a call to an `e2e_*` helper that this file separately proves always returns 0.
_check_cleanup_statements_cannot_fail() {
  local f="$1" body offenders
  body="$(_cleanup_body "$f")"
  [ -n "$body" ] || { echo "$f has no cleanup() function to inspect"; return 1; }
  # JOIN CONTINUATIONS FIRST. e2e-proxy.sh's bounded `docker rm -f` carries its
  # `|| echo …` on the next line, so a line-at-a-time check reads the first half as
  # a statement that can fail. A checker that cannot see a statement whole reports
  # violations that are not there — and would miss real ones spelled the other way.
  offenders="$(printf '%s\n' "$body" \
    | awk '{ if (buf != "") { $0 = buf " " $0; buf = "" }
             if (sub(/\\[[:space:]]*$/, "")) { buf = $0; next }
             print }' \
    | grep -vE '^[[:space:]]*(#|\}|$)' \
    | grep -vE '^cleanup\(\)' \
    | grep -vE '^[[:space:]]*local[[:space:]]+_status=\$\?[[:space:]]*$' \
    | grep -vE '^[[:space:]]*return[[:space:]]+"\$_status"[[:space:]]*$' \
    | grep -vE '^[[:space:]]*(if|fi|then|else|elif|for|done|do|case|esac|\{|\})' \
    | grep -vE '^[[:space:]]*e2e_[a-z_]+([[:space:]]|$)' \
    | grep -vE '\|\|[[:space:]]*(true|:|echo|printf)' || true)"
  [ -z "$offenders" ] || {
    echo "$f's cleanup() has statement(s) that can end non-zero — errexit is live in an EXIT trap, so a failure there aborts it, discarding the harness's verdict AND skipping every later reap (client#979):"
    printf '%s\n' "$offenders"
    echo "Route file/dir removal through e2e_reap_path, or terminate the statement with '|| true'."
    return 1
  }
}

# The verdict discipline: `local _status=$?` FIRST (before anything can move $?)
# and `return "$_status"` LAST. Position is the whole assertion — a capture after
# the first command captures the wrong value, and a `return` that is not last
# leaves a later failing command as the script's exit status.
_check_cleanup_preserves_status() {
  local f="$1" body first last
  body="$(_cleanup_body "$f")"
  [ -n "$body" ] || { echo "$f has no cleanup() function to inspect"; return 1; }
  first="$(printf '%s\n' "$body" | sed -n '2,$p' | grep -vE '^[[:space:]]*(#|$)' | head -1)"
  last="$(printf '%s\n' "$body" | grep -vE '^[[:space:]]*(#|\}|$)' | tail -1)"
  printf '%s' "$first" | grep -qE '^[[:space:]]*local[[:space:]]+_status=\$\?[[:space:]]*$' || {
    echo "$f's cleanup() must capture the harness's verdict as its FIRST statement ('local _status=\$?'); found: ${first:-<nothing>}"
    return 1
  }
  printf '%s' "$last" | grep -qE '^[[:space:]]*return[[:space:]]+"\$_status"[[:space:]]*$' || {
    echo "$f's cleanup() must end with 'return \"\$_status\"', or a later non-zero command becomes the job's verdict (client#979); found: ${last:-<nothing>}"
    return 1
  }
}

# ── the census: did the derivation actually look? ────────────────────────────

@test "the harness list is derived from the tree and is NOT empty (the census)" {
  local n
  n="$(_harnesses | grep -c . || true)"
  [ "$n" -ge "$HARNESS_FLOOR" ] || {
    echo "derived $n k3d e2e harness(es) from $TESTS_DIR but at least $HARNESS_FLOOR are known to exist — the glob or the create_cluster filter has gone vacuous, and every loop in this file would then pass while checking nothing"
    return 1
  }
}

@test "the derivation finds all seven known harnesses by name (the floor is honest)" {
  # Names are asserted HERE and nowhere else: the checks below iterate the derived
  # list, so this is the one place a silently-dropped harness can be caught. A
  # floor alone would survive one harness disappearing and another appearing.
  local found h
  found="$(_harnesses)"
  for h in e2e-mysql e2e-cluster e2e-seal-check e2e-auto-upgrade e2e-full-seal e2e-journey e2e-proxy; do
    printf '%s\n' "$found" | grep -q "/${h}.sh\$" || {
      echo "$h.sh is no longer in the derived harness list — if it was renamed or retired, say so; if the derivation broke, fix it"
      return 1
    }
  done
}

# ── the three properties, per harness ───────────────────────────────────────

@test "no harness spells 'k3d cluster delete' itself (client#979)" {
  local f rc=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_no_direct_delete "$f" || rc=1
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
}

@test "every harness traps cleanup on EXIT" {
  local f rc=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_traps_cleanup "$f" || rc=1
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
}

@test "every harness's cleanup reaps the cluster through the shared bounded helper" {
  local f rc=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_cleanup_calls_shared_reap "$f" || rc=1
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
}

@test "no cleanup calls the Docker engine without a deadline (the class, not just the k3d delete)" {
  local f rc=0 seen=0 hf hseen=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_cleanup_engine_calls_bounded "$f" || rc=1
    seen=$(( seen + $(_count_cleanup_engine_calls "$f") ))
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1

  # ── THE CENSUS, POINTED AT WHERE THE ENGINE CALLS ACTUALLY LIVE ─────────────
  # This used to require `seen >= 1`, on the premise that "the remaining engine
  # calls in these traps are e2e-proxy's squid removal". That premise expired
  # when the squid reap moved into e2e_reap_container (saqlainsyed007's rc-124
  # finding): with BOTH reaps extracted, `seen` is legitimately 0 — which is the
  # goal, not a regression, since a harness spelling an engine call inline is
  # exactly what the loop above forbids.
  #
  # A census whose subject has moved must follow it, not be relaxed. So `seen`
  # keeps its floor of ZERO deliberately — the loop above is the guard, and it is
  # driven against planted fixtures below — and the "did it look?" assertion moves
  # to the shared helpers, where every engine call in these traps now is. That is
  # strictly more coverage than before: it inspects the cluster delete too, which
  # the old `seen >= 1` never reached.
  for hf in e2e_cleanup_cluster e2e_reap_container; do
    grep -qE "^${hf}\(\)" "$COMMON" || {
      echo "$COMMON has no ${hf}() — the harness cleanups delegate every engine call to these helpers, so a missing one means the bound is nowhere"
      return 1
    }
    _check_helper_engine_calls_bounded "$hf" || return 1
    hseen=$(( hseen + $(_count_helper_engine_calls "$hf") ))
  done
  [ "$hseen" -ge 2 ] || {
    echo "inspected $hseen docker/k3d call(s) across the shared reap helpers, expected at least 2 (the k3d delete + the docker removal) — the extraction went vacuous, so this check passed while examining nothing"
    return 1
  }
}

@test "no cleanup statement can end non-zero (errexit is live in an EXIT trap)" {
  local f rc=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_cleanup_statements_cannot_fail "$f" || rc=1
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
}

@test "every harness's cleanup preserves the script's exit status (verdict, not outcome)" {
  local f rc=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_cleanup_preserves_status "$f" || rc=1
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
}

# The text assertions above pin the SHAPE. This drives the PROPERTY: each real
# cleanup() is extracted and RUN as an EXIT trap under `set -euo pipefail`, with
# the reap mocked, and the harness's verdict must come out the other side — even
# though every one of these functions still performs its own extra reaps, any of
# which could end non-zero and clobber it.
@test "every harness's real cleanup(), run as an EXIT trap, hands back the verdict it was given" {
  local f n=0
  while read -r f; do
    [ -n "$f" ] || continue
    local body script
    body="$(_cleanup_body "$f")"
    [ -n "$body" ] || { echo "no cleanup() in $f"; return 1; }
    script="$BATS_TEST_TMPDIR/drive-$(basename "$f")"
    {
      printf 'set -euo pipefail\n'
      # Everything the extracted bodies reference, plus a reap that FAILS — the
      # helper promises 0, and this proves the caller does not depend on that.
      printf 'CLUSTER_NAME=throwaway\n'
      printf 'CREDS_FILE=""\n'
      printf 'WORKDIR="%s/wd"; mkdir -p "$WORKDIR"\n' "$BATS_TEST_TMPDIR"
      printf 'WORK="%s/wk"; mkdir -p "$WORK"\n' "$BATS_TEST_TMPDIR"
      printf 'SQUID_NAME=squid-absent\n'
      # `_bounded() { shift; "$@"; }` so the docker mock below is the thing that
      # actually runs — the real _bounded execs `timeout`, a BINARY, which cannot
      # see a shell-function stub (the #741 test trap). Without it this would
      # exercise a "command not found", not a failing docker.
      printf '_bounded() { shift; "$@"; }\n'
      printf 'docker() { return 1; }\n'
      # SOURCE THE REAL e2e-common.sh, then override only the cluster reap. The
      # first version stubbed both helpers, so a cleanup calling a helper that did
      # not exist would have passed — and a missing helper inside an errexit trap
      # is a 127 that overwrites the verdict exactly like a failing `rm`. Driven
      # here rather than trusted: every harness sources this file strictly before
      # `trap cleanup EXIT`, which is what makes that impossible in a real run.
      printf 'source "%s"\n' "$COMMON"
      printf 'e2e_cleanup_cluster() { echo "reaped" >&2; return 0; }\n'
      printf '%s\n' "$body"
      printf 'trap cleanup EXIT\n'
      printf 'exit 7\n'
    } > "$script"
    run bash "$script"
    [ "$status" -eq 7 ] || {
      echo "$f's cleanup() turned an exit 7 into $status — that is the client#979 verdict loss, in this file"
      echo "$output"
      return 1
    }
    n=$((n + 1))
  done <<< "$(_harnesses)"
  [ "$n" -ge "$HARNESS_FLOOR" ] || { echo "drove only $n cleanup(s); the loop went vacuous"; return 1; }
}

# THE CASE THIS GUARD WAS MISSING, and the reason it is worth naming: the test
# above drove every real cleanup with `CREDS_FILE=""`, i.e. in the one state where
# the `rm` never runs — so the failing-rm branch was never exercised for
# e2e-full-seal.sh and the guard reported coverage it did not have. A test that
# drives the right function in a state where the bug cannot occur is not a test.
@test "every harness's cleanup survives a HOSTILE filesystem (verdict AND reap both intact)" {
  # Every path variable points somewhere unremovable: a file inside a mode-0500
  # directory, which is exactly what a read-only mount or a root-owned parent looks
  # like. `rm` fails, and the harness's exit 7 must still come out the other side
  # WITH the cluster reap having run — the pre-fix shape lost both at once.
  local locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked"
  : > "$locked/creds"
  : > "$locked/work"
  chmod 500 "$locked"

  local f n=0
  while read -r f; do
    [ -n "$f" ] || continue
    local body script out
    body="$(_cleanup_body "$f")"
    [ -n "$body" ] || { echo "no cleanup() in $f"; return 1; }
    script="$BATS_TEST_TMPDIR/hostile-$(basename "$f")"
    {
      printf 'set -euo pipefail\n'
      printf 'CLUSTER_NAME=throwaway\n'
      # THE POINT: non-empty, and unremovable.
      printf 'CREDS_FILE="%s/creds"\n' "$locked"
      printf 'WORKDIR="%s/work"\n' "$locked"
      printf 'WORK="%s/work"\n' "$locked"
      printf 'SQUID_NAME=squid-absent\n'
      printf '_bounded() { shift; "$@"; }\n'
      printf 'docker() { return 1; }\n'
      # The REAL e2e_reap_path, from the real file — a re-implementation here would
      # only prove the copy in this test always returns 0.
      printf 'source "%s"\n' "$COMMON"
      printf 'e2e_cleanup_cluster() { echo "REAP-RAN" >&2; return 0; }\n'
      printf '%s\n' "$body"
      printf 'trap cleanup EXIT\n'
      printf 'exit 7\n'
    } > "$script"
    run bash "$script"
    [ "$status" -eq 7 ] || {
      chmod 700 "$locked"
      echo "$f: an unremovable path turned exit 7 into $status — the harness's verdict was replaced by the rm's status (client#979)"
      echo "$output"
      return 1
    }
    printf '%s\n' "$output" | grep -q REAP-RAN || {
      chmod 700 "$locked"
      echo "$f: the cluster reap did NOT run after the failing rm — the trap aborted early, so the cluster leaks as well as the verdict"
      echo "$output"
      return 1
    }
    n=$((n + 1))
  done <<< "$(_harnesses)"
  chmod 700 "$locked"
  [ "$n" -ge "$HARNESS_FLOOR" ] || { echo "drove only $n cleanup(s) — the loop went vacuous"; return 1; }
}

# ── the shared helper itself ────────────────────────────────────────────────

@test "e2e_cleanup_cluster exists in e2e-common.sh and BOUNDS the delete" {
  grep -qE '^e2e_cleanup_cluster\(\)' "$COMMON" || return 1
  local body
  body="$(awk '/^e2e_cleanup_cluster\(\)/{f=1} f{print} f&&/^\}/{exit}' "$COMMON")"
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | grep -qE '_bounded[[:space:]]+"\$secs"[[:space:]]+k3d[[:space:]]+cluster[[:space:]]+delete' || {
    echo "the delete in e2e_cleanup_cluster is not wrapped in _bounded — 'k3d cluster delete' takes no --timeout of its own and blocks against an unhappy Docker engine (client#979)"
    return 1
  }
}

@test "e2e_cleanup_cluster does NOT silence the delete (the 24 invisible minutes)" {
  local body
  body="$(awk '/^e2e_cleanup_cluster\(\)/{f=1} f{print} f&&/^\}/{exit}' "$COMMON")"
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | grep -E 'k3d[[:space:]]+cluster[[:space:]]+delete' | grep -vE '^[[:space:]]*#' \
    | grep -qE '>[[:space:]]*/dev/null' && {
      echo "the delete's output is redirected to /dev/null — that is what made the stall invisible in the client#977 log; a cleanup that cannot complete must leave one attributable line"
      return 1
    }
  # And it must actually SAY something on a timeout, not just stop redirecting.
  printf '%s\n' "$body" | grep -q 'TIMED OUT' || {
    echo "e2e_cleanup_cluster prints nothing when its deadline fires — the next occurrence would again be unattributable from the log alone"
    return 1
  }
}

@test "e2e_cleanup_cluster always returns 0 (cleanup is a note, never the outcome)" {
  # Driven, not read: errexit is live inside an EXIT trap, so a helper that let a
  # non-zero status escape would abort the trap and overwrite the harness's
  # verdict. Exercise the real function with a failing delete.
  local out
  out="$(bash -c '
    set -euo pipefail
    _bounded() { return 124; }
    k3d() { return 1; }
    CLUSTER_NAME=throwaway
    source "'"$COMMON"'"
    e2e_cleanup_cluster 5
    echo "RETURNED-0"
  ' 2>/dev/null)"
  [ "$out" = "RETURNED-0" ] || {
    echo "e2e_cleanup_cluster did not return 0 on a failing delete (got: ${out:-<aborted>})"
    return 1
  }
}

@test "e2e_reap_path always returns 0, and says what it could not remove" {
  # The helper the hostile-filesystem case relies on. Driven against a real
  # unremovable path, not a mock: `rm -rf` on a file inside a mode-0500 directory.
  local locked="$BATS_TEST_TMPDIR/reap-locked" out rc=0
  mkdir -p "$locked"; : > "$locked/f"; chmod 500 "$locked"
  out="$(bash -c '
    set -euo pipefail
    source "'"$COMMON"'"
    e2e_reap_path "'"$locked"'/f"
    echo RETURNED-0
  ' 2>&1)" || rc=$?
  chmod 700 "$locked"
  [ "$rc" -eq 0 ] || { echo "e2e_reap_path aborted under set -e (rc=$rc): $out"; return 1; }
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0: $out"; return 1 ;; esac
  case "$out" in *"could not remove"*) ;; *) echo "removed nothing and said nothing: $out"; return 1 ;; esac
}

@test "e2e_reap_path removes what it CAN, and is quiet about a path that was never there" {
  local d="$BATS_TEST_TMPDIR/reap-ok" out
  mkdir -p "$d"; : > "$d/gone"
  out="$(bash -c '
    set -euo pipefail
    source "'"$COMMON"'"
    e2e_reap_path "'"$d"'/gone" "" "'"$d"'/never-existed"
    echo RETURNED-0
  ' 2>&1)"
  [ ! -e "$d/gone" ] || { echo "did not remove a removable file"; return 1; }
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0: $out"; return 1 ;; esac
  case "$out" in *"could not remove"*) echo "complained about an absent path or an empty arg: $out"; return 1 ;; esac
}

@test "e2e_reap_container DISTINGUISHES the deadline (124) from any other failure" {
  # THE FINDING (saqlainsyed007, client#979). The one-line form this replaced said
  # "could not remove … within ${TB_E2E_DELETE_TIMEOUT:-120}s" for ANY non-zero rc,
  # so the common case — the harness dying before `docker run`, leaving no
  # container — was logged as a timeout that never happened. Driven, all three
  # outcomes, because a message is the ENTIRE deliverable of this helper: it
  # cannot fix anything, it can only say what happened.
  local out

  # 1. THE DEADLINE ACTUALLY FIRED. Must name the timeout.
  out="$(bash -c '
    _bounded() { if [ "$3" = "inspect" ]; then return 0; fi; return 124; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
    echo RETURNED-0
  ' 2>&1)"
  case "$out" in *"TIMED OUT"*) ;; *) echo "a real deadline hit did not say TIMED OUT: $out"; return 1 ;; esac
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0 on a timeout: $out"; return 1 ;; esac

  # 2. A DOCKER ERROR ON AN EXISTING CONTAINER. Must NOT claim a timeout, and must
  #    say the deadline did not fire — otherwise it is the old conflation again.
  out="$(bash -c '
    _bounded() { if [ "$3" = "inspect" ]; then return 0; fi; return 1; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
    echo RETURNED-0
  ' 2>&1)"
  case "$out" in *"TIMED OUT"*) echo "reported a TIMEOUT for rc=1, which is the exact conflation this fixes: $out"; return 1 ;; esac
  case "$out" in *"within 5s"*) echo "still says 'within Ns' for a non-timeout failure: $out"; return 1 ;; esac
  case "$out" in *"exited 1"*) ;; *) echo "did not name the actual exit code: $out"; return 1 ;; esac
  case "$out" in *"did NOT fire"*) ;; *) echo "did not say the deadline was not the cause: $out"; return 1 ;; esac
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0 on a docker error: $out"; return 1 ;; esac

  # 3. THE CONTAINER WAS NEVER CREATED. Not a failure at all — and above all not a
  #    timeout. This is the case the old line got wrong most of the time.
  out="$(bash -c '
    _bounded() { if [ "$3" = "inspect" ]; then return 1; fi; echo "REMOVE-ATTEMPTED"; return 0; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
    echo RETURNED-0
  ' 2>&1)"
  case "$out" in *"TIMED OUT"*) echo "reported a TIMEOUT for an absent container: $out"; return 1 ;; esac
  case "$out" in *"within 5s"*) echo "reported a deadline for an absent container: $out"; return 1 ;; esac
  case "$out" in *REMOVE-ATTEMPTED*) echo "ran 'docker rm -f' against a container it had just found absent: $out"; return 1 ;; esac
  case "$out" in *"never created"*) ;; *) echo "did not explain that there was nothing to remove: $out"; return 1 ;; esac
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0 for an absent container: $out"; return 1 ;; esac

  # 4. THE ENGINE IS WEDGED, so the EXISTENCE PROBE is what times out. The probe
  #    carries the same trap as the removal: "inspect said non-zero" is not the
  #    same fact as "the container is not there", and collapsing the two would
  #    announce "it was never created" about a container that exists on an engine
  #    that has stopped talking — silently skipping the removal, and saying
  #    nothing about the stall that is the entire subject of client#979.
  out="$(bash -c '
    _bounded() { return 124; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
    echo RETURNED-0
  ' 2>&1)"
  case "$out" in *"never created"*) echo "a TIMED-OUT existence probe was reported as an absent container: $out"; return 1 ;; esac
  case "$out" in *"already gone"*) echo "a TIMED-OUT existence probe was reported as already gone: $out"; return 1 ;; esac
  case "$out" in *"TIMED OUT"*) ;; *) echo "a wedged engine on the existence probe produced no stall report: $out"; return 1 ;; esac
  case "$out" in *UNKNOWN*) ;; *) echo "did not say the container's existence was undetermined: $out"; return 1 ;; esac
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0 when the probe timed out: $out"; return 1 ;; esac
}

@test "e2e_reap_container always returns 0, and refuses to run UNBOUNDED" {
  # The two properties it shares with e2e_cleanup_cluster: a non-zero escaping a
  # helper called from an EXIT trap would abort the trap and discard the verdict,
  # and running the removal with no deadline is the defect itself.
  local out
  out="$(bash -c '
    set -euo pipefail
    _bounded() { return 1; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
    echo RETURNED-0
  ' 2>/dev/null)"
  [ "$out" = "RETURNED-0" ] || { echo "did not return 0 under errexit with everything failing (got: ${out:-<aborted>})"; return 1; }

  # No _bounded on PATH (common.sh unsourced) -> skip and say so, never run bare.
  out="$(bash -c '
    set -euo pipefail
    docker() { echo "DOCKER-RAN-UNBOUNDED"; }
    source "'"$COMMON"'"
    e2e_reap_container squid 5
  ' 2>&1)"
  case "$out" in *DOCKER-RAN-UNBOUNDED*) echo "ran the removal with no bound: $out"; return 1 ;; esac
  case "$out" in *SKIPPING*) ;; *) echo "no skip note emitted: $out"; return 1 ;; esac

  # And an empty name is a no-op, not a `docker rm -f ""`.
  out="$(bash -c '
    set -euo pipefail
    _bounded() { echo "BOUNDED-RAN"; }
    source "'"$COMMON"'"
    e2e_reap_container ""
    echo RETURNED-0
  ' 2>&1)"
  case "$out" in *BOUNDED-RAN*) echo "acted on an empty container name: $out"; return 1 ;; esac
  case "$out" in *RETURNED-0*) ;; *) echo "did not return 0 for an empty name: $out"; return 1 ;; esac
}

@test "e2e_cleanup_cluster refuses to run the delete UNBOUNDED when _bounded is missing" {
  # Fail toward "don't hang". A leftover throwaway cluster on an ephemeral runner
  # costs nothing; running the delete with no bound is the defect itself.
  local out
  out="$(bash -c '
    set -euo pipefail
    k3d() { echo "K3D-RAN-UNBOUNDED"; }
    CLUSTER_NAME=throwaway
    source "'"$COMMON"'"
    e2e_cleanup_cluster 5
  ' 2>&1)"
  case "$out" in *K3D-RAN-UNBOUNDED*) echo "ran the delete with no bound: $out"; return 1 ;; esac
  case "$out" in *SKIPPING*) ;; *) echo "no skip note emitted: $out"; return 1 ;; esac
}

# ── the macOS caveat: ASSERTED, not assumed ─────────────────────────────────
# `_bounded` runs the BARE command when neither timeout(1) nor gtimeout(1) is on
# PATH, and neither ships on a stock Mac — a caveat that is real elsewhere in
# this repo (backend#2521, #741, #832). It does not apply to these harnesses
# because every job that runs one is on an `ubuntu-*` runner. That is a fact
# about the workflows, so it is read FROM the workflows: the moment someone adds
# a macos-*/windows-* job that runs a harness, this reddens and the bound has to
# be re-derived from a coreutils-free mechanism.
#
# THE FIRST SHAPE OF THIS CHECK COULD NOT DEFEND THAT PREMISE (Bugbot Medium +
# LukasWodka, both driven against the real workflow files). It grepped runner
# declarations out of the WHOLE workflow and tested each captured LINE against
# `*ubuntu*`, which lost the premise two separate ways:
#
#   1. A MIXED ARRAY SATISFIED IT. `os: [ubuntu-latest, windows-latest]` — the
#      literal shape installer-tests.yaml already declares, in the very workflow
#      that runs e2e-cluster.sh — contains `ubuntu`, so the line passed while the
#      windows leg went unexamined. A macos e2e leg would hide identically.
#   2. A BRACKETED `runs-on:` WAS INVISIBLE. `[` is outside the capture regex's
#      `[A-Za-z0-9._-]` class, so `runs-on: [self-hosted, macOS, arm64]` yielded
#      no line at all — no finding AND no increment of the vacuity counter, so
#      the `>= 4` floor stayed satisfied by the other legs. That half is the
#      worse of the two: a check that cannot tell "clean" from "didn't look",
#      inside the guard whose whole job was to look.
#
# So runners are now RESOLVED PER JOB and expanded ONE ENTRY PER MATRIX ELEMENT,
# and a declaration the resolver cannot read is reported as UNRESOLVED rather
# than dropped. Per JOB and not per workflow, because whole-workflow scoping
# stops being merely "strictly stronger" the moment the array is split: it
# becomes UNSATISFIABLE, since installer-tests.yaml legitimately runs Pester on
# `windows-latest` in a job that runs no harness at all. Job scoping is what
# makes this assertion both true and enforceable.

# ── _wf_harness_runners <workflow> ──────────────────────────────────────────
# Emit tab-separated `<job>\t<kind>\t<value>` records for every job in
# <workflow> that runs an e2e harness:
#
#   <job>  HARNESS     e2e-cluster.sh[,e2e-…]   the harness(es) that job invokes
#   <job>  RUNNER      ubuntu-24.04-arm         ONE record per resolved runner
#   <job>  UNRESOLVED  <why>                    a declaration it cannot read
#
# Job blocks are tracked by indentation under `jobs:` — enough structure for
# exactly these three keys, and no YAML parser to add to the repo. Resolution
# covers a scalar `runs-on:`, a bracketed `runs-on: [a, b]`, and
# `runs-on: ${{ matrix.KEY }}` against that job's own `matrix:` block in either
# inline (`KEY: [a, b]`) or block (`KEY:` / `- a`) form. Anything else — an
# unknown matrix key, a `fromJSON(...)`, a job with no `runs-on:` at all — is
# emitted as UNRESOLVED, never silently omitted: omission is what made the
# bracketed form pass twice over. Comment lines are skipped, so a commented-out
# harness invocation does not conjure a job.
_wf_harness_runners() {
  awk '
    function ind_of(s) { match(s, /^ */); return RLENGTH }
    function emit(j, csv,    parts, m, i, t, cnt, q) {
      q = sprintf("%c", 39)
      cnt = 0
      m = split(csv, parts, ",")
      for (i = 1; i <= m; i++) {
        t = parts[i]
        gsub("[" q "\"]", "", t)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        if (t == "") continue
        print j "\tRUNNER\t" t
        cnt++
      }
      if (cnt == 0) print j "\tUNRESOLVED\trunner list parsed to zero entries: [" csv "]"
    }
    BEGIN { job_indent = -1; cur = ""; in_jobs = 0; matrix_indent = -1; mkey = ""; mkey_indent = -1; n = 0 }
    {
      line = $0
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*#/) next
      ind = ind_of(line)
      if (line ~ /^jobs:[[:space:]]*$/) { in_jobs = 1; next }
      if (in_jobs && ind == 0) { in_jobs = 0; cur = ""; next }
      if (!in_jobs) next
      if (job_indent < 0) job_indent = ind
      if (ind <= job_indent) {
        if (ind == job_indent && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/) {
          cur = line; sub(/^[[:space:]]*/, "", cur); sub(/:[[:space:]]*$/, "", cur)
          order[++n] = cur
          matrix_indent = -1; mkey = ""; mkey_indent = -1
        }
        next
      }
      if (cur == "") next
      if (match(line, /bash[[:space:]]+scripts\/tests\/e2e-[a-z-]+\.sh/)) {
        h = substr(line, RSTART, RLENGTH); sub(/^.*\//, "", h)
        harness[cur] = 1
        if (!((cur SUBSEP h) in hseen)) { hseen[cur SUBSEP h] = 1; hn[cur] = hn[cur] "," h }
      }
      if (matrix_indent >= 0 && ind <= matrix_indent) { matrix_indent = -1; mkey = ""; mkey_indent = -1 }
      if (line ~ /^[[:space:]]*matrix:[[:space:]]*$/) { matrix_indent = ind; mkey = ""; mkey_indent = -1; next }
      if (matrix_indent >= 0 && ind > matrix_indent) {
        if (match(line, /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*\[[^]]*\]/)) {
          k = line; sub(/^[[:space:]]*/, "", k); sub(/:.*$/, "", k)
          v = line; sub(/^[^[]*\[/, "", v); sub(/\].*$/, "", v)
          mv[cur SUBSEP k] = v; mkey = ""; mkey_indent = -1; next
        }
        if (line ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/) {
          mkey = line; sub(/^[[:space:]]*/, "", mkey); sub(/:[[:space:]]*$/, "", mkey)
          mkey_indent = ind; next
        }
        if (mkey != "" && ind > mkey_indent && line ~ /^[[:space:]]*-[[:space:]]*[^[:space:]]/) {
          v = line; sub(/^[[:space:]]*-[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
          if (mv[cur SUBSEP mkey] == "") mv[cur SUBSEP mkey] = v
          else mv[cur SUBSEP mkey] = mv[cur SUBSEP mkey] "," v
          next
        }
      }
      if (match(line, /^[[:space:]]*runs-on:[[:space:]]*/)) {
        v = line; sub(/^[[:space:]]*runs-on:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        ro[cur] = v
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        j = order[i]
        if (!(j in harness)) continue
        hl = hn[j]; sub(/^,/, "", hl)
        print j "\tHARNESS\t" hl
        if (!(j in ro) || ro[j] == "") { print j "\tUNRESOLVED\tno runs-on: found in this job"; continue }
        v = ro[j]
        if (v ~ /^\[/) { sub(/^\[/, "", v); sub(/\].*$/, "", v); emit(j, v); continue }
        if (v ~ /\$\{\{/) {
          if (match(v, /matrix\.[A-Za-z0-9_.-]+/)) {
            key = substr(v, RSTART + 7, RLENGTH - 7)
            if ((j SUBSEP key) in mv) { emit(j, mv[j SUBSEP key]); continue }
            print j "\tUNRESOLVED\truns-on is matrix." key " but no matrix." key " values were parsed for this job"
            continue
          }
          print j "\tUNRESOLVED\truns-on is an expression this check cannot resolve: " v
          continue
        }
        emit(j, v)
      }
    }
  ' "$1"
}

# ── _check_ubuntu_runners <workflows_dir> ───────────────────────────────────
# The enforcement half, as a FUNCTION so the not-vacuous self-tests below can
# drive the same code CI trusts against planted workflow fixtures — an @test
# body cannot be called, and a paraphrase of it in a fixture is exactly the
# "measures a copy, not the code" trap this file already pins elsewhere.
# Sets RUNNERS_SEEN and HARNESSES_COVERED for the caller's census.
_check_ubuntu_runners() {
  local dir="$1" wf out job kind val wf_jobs tab
  tab="$(printf '\t')"
  RUNNERS_SEEN=0
  HARNESSES_COVERED=","
  for wf in "$dir"/*.yaml "$dir"/*.yml; do
    [ -f "$wf" ] || continue
    grep -qE 'bash scripts/tests/e2e-[a-z-]+\.sh' "$wf" || continue
    out="$(_wf_harness_runners "$wf")"
    wf_jobs=0
    while IFS="$tab" read -r job kind val; do
      [ -n "$job" ] || continue
      case "$kind" in
        HARNESS)
          wf_jobs=$((wf_jobs + 1))
          HARNESSES_COVERED="${HARNESSES_COVERED}${val},"
          ;;
        UNRESOLVED)
          echo "$(basename "$wf") job '$job' runs an e2e harness but its runner could not be resolved — $val. An unreadable runner declaration is NOT a pass: a bracketed 'runs-on: [self-hosted, macOS, arm64]' being invisible is how a non-ubuntu e2e leg previously went both unreported and uncounted (client#979 review). Teach the resolver that shape, or move the leg to ubuntu-*."
          return 1
          ;;
        RUNNER)
          RUNNERS_SEEN=$((RUNNERS_SEEN + 1))
          # PREFIX-anchored, not `*ubuntu*`: the substring form also accepts a
          # label that merely mentions ubuntu (`macos-ubuntu-builder`), the same
          # "close enough to pass" slack that let the mixed array through one
          # level up.
          case "$val" in
            ubuntu*) ;;
            *)
              echo "$(basename "$wf") job '$job' runs an e2e harness on runner '$val', which is not an ubuntu-* runner — _bounded is a NO-OP where neither timeout(1) nor gtimeout(1) is on PATH (a stock Mac has neither), so the client#979 bound would not exist on that leg and the 24-minute trap stall comes back unbounded."
              return 1
              ;;
          esac
          ;;
      esac
    done <<< "$out"
    [ "$wf_jobs" -ge 1 ] || {
      echo "$(basename "$wf") invokes an e2e harness but the job resolver found NO harness-running job in it — the parse went vacuous, so every assertion in this check examined nothing for this workflow"
      return 1
    }
  done
  return 0
}

@test "every workflow job that runs an e2e harness is on an ubuntu runner (so _bounded really bounds)" {
  local h missing=""
  # Called DIRECTLY, not through a command substitution: a subshell would keep
  # RUNNERS_SEEN / HARNESSES_COVERED from reaching the census below, and this
  # file has already lost a guard to a `local`-plus-substitution swallowing an
  # exit status (see the `local`-splitting commit on this branch). bats prints
  # the check's own stdout when the test fails, so the reason still surfaces.
  _check_ubuntu_runners "$REPO/.github/workflows" || return 1

  # ── NON-VACUITY, asserted rather than inferred ──────────────────────────────
  # A floor on the NUMBER of runner declarations — what this test used to assert
  # — cannot tell "all seven legs examined" from "one leg silently unparsed and
  # the others made up the count". That is exactly how the bracketed `runs-on:`
  # slipped through, so the floor is replaced by a per-harness CENSUS: every
  # harness this file derives must have been resolved to at least one job.
  for h in $(_harnesses); do
    case "$HARNESSES_COVERED" in
      *",$(basename "$h"),"*) ;;
      *) missing="$missing $(basename "$h")" ;;
    esac
  done
  [ -z "$missing" ] || {
    echo "these e2e harnesses were resolved to NO workflow job by this check:$missing — either CI no longer runs them (then the ubuntu premise above is unasserted for them and _bounded's macOS no-op is back in play) or the resolver stopped seeing their job. Both are failures; neither is a pass."
    return 1
  }
  # And every resolved job must have yielded at least one RUNNER record, so a
  # resolver that emits HARNESS lines while silently dropping runners cannot
  # satisfy the census above while checking nothing.
  [ "$RUNNERS_SEEN" -ge "$HARNESS_FLOOR" ] || {
    echo "resolved $RUNNERS_SEEN runner declaration(s) across the harness workflows but the census knows of at least $HARNESS_FLOOR harnesses — fewer runners than harnesses means at least one job contributed none"
    return 1
  }
}

# ── not vacuous: the checks are driven against planted fixtures ─────────────
# A guard nobody has watched fail is not a guard. These build both the pre-fix
# and post-fix harness shapes and run the SAME check functions CI runs.

@test "the cleanup extractor reads BOTH spellings and over-reads neither" {
  # The pre-fix one-liner and the post-fix block. An extractor that swallows past
  # a one-line cleanup makes every check below measure the whole harness.
  local one="$BATS_TEST_TMPDIR/one.sh" many="$BATS_TEST_TMPDIR/many.sh" out
  printf 'cleanup() { k3d cluster delete "$C" >/dev/null 2>&1 || true; }\ntrap cleanup EXIT\nDO_NOT_READ_ME=1\n' > "$one"
  out="$(_cleanup_body "$one")"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || { echo "over-read the one-liner: $out"; return 1; }
  case "$out" in *DO_NOT_READ_ME*) echo "over-read past the one-liner"; return 1 ;; esac
  printf 'cleanup() {\n  local _status=$?\n  e2e_cleanup_cluster\n  return "$_status"\n}\ntrap cleanup EXIT\nDO_NOT_READ_ME=1\n' > "$many"
  out="$(_cleanup_body "$many")"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 5 ] || { echo "misread the block form: $out"; return 1; }
  case "$out" in *DO_NOT_READ_ME*) echo "over-read past the block form"; return 1 ;; esac
}

@test "the checks FIRE on the pre-fix harness shape (all three properties broken)" {
  local dir="$BATS_TEST_TMPDIR/prefix" f="$BATS_TEST_TMPDIR/prefix/e2e-fixture.sh"
  mkdir -p "$dir"
  {
    printf 'set -euo pipefail\n'
    printf 'create_cluster\n'
    printf 'cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }\n'
    printf 'trap cleanup EXIT\n'
  } > "$f"
  # derived: the fixture IS picked up (else the rest proves nothing)
  [ "$(_harnesses "$dir" | grep -c . || true)" -eq 1 ] || return 1
  run _check_no_direct_delete "$f"
  [ "$status" -ne 0 ] || return 1
  run _check_cleanup_calls_shared_reap "$f"
  [ "$status" -ne 0 ] || return 1
  run _check_cleanup_preserves_status "$f"
  [ "$status" -ne 0 ] || return 1
}

@test "the checks SPARE the fixed harness shape (the rule is satisfiable)" {
  local dir="$BATS_TEST_TMPDIR/fixed" f="$BATS_TEST_TMPDIR/fixed/e2e-fixture.sh"
  mkdir -p "$dir"
  {
    printf 'set -euo pipefail\n'
    printf 'create_cluster\n'
    printf 'cleanup() {\n'
    printf '  local _status=$?\n'
    printf '  e2e_cleanup_cluster\n'
    printf '  rm -rf "$WORK" 2>/dev/null || true\n'
    printf '  return "$_status"\n'
    printf '}\n'
    printf 'trap cleanup EXIT\n'
  } > "$f"
  run _check_no_direct_delete "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run _check_traps_cleanup "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run _check_cleanup_calls_shared_reap "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run _check_cleanup_preserves_status "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a capture that is not FIRST, or a return that is not LAST, is still caught" {
  # The two near-misses a looser 'does it contain the strings' check would pass.
  # Both were real risks here: e2e-proxy.sh's trap ended with `rm -rf "$WORK"`,
  # whose status WAS the one the job reported.
  # SEPARATE `local` statements, not `local dir=… late="$dir/…"`: in one `local`
  # every name is created before any value is expanded, so `$dir` is EMPTY on the
  # right-hand side of a later assignment in the SAME statement — the paths came
  # out as `/e2e-late.sh` and the mkdir died with "Permission denied". Local bash
  # 3.2 tolerated it and Linux CI did not, which is the direction this repo's
  # macOS-vs-CI blindspot usually runs.
  local dir="$BATS_TEST_TMPDIR/nearmiss"
  local late="$dir/e2e-late.sh"
  local early="$dir/e2e-early.sh"
  mkdir -p "$dir"
  {
    printf 'create_cluster\n'
    printf 'cleanup() {\n'
    printf '  e2e_cleanup_cluster\n'
    printf '  local _status=$?\n'                 # captured AFTER the reap: wrong value
    printf '  return "$_status"\n'
    printf '}\n'
  } > "$late"
  {
    printf 'create_cluster\n'
    printf 'cleanup() {\n'
    printf '  local _status=$?\n'
    printf '  return "$_status"\n'
    printf '  e2e_cleanup_cluster\n'
    printf '  rm -rf "$WORK"\n'                   # after the return: status leaks
    printf '}\n'
  } > "$early"
  run _check_cleanup_preserves_status "$late"
  [ "$status" -ne 0 ] || return 1
  run _check_cleanup_preserves_status "$early"
  [ "$status" -ne 0 ] || return 1
}

# ── the mechanism itself, proven rather than asserted ───────────────────────

@test "a failing command in an EXIT trap DOES overwrite the exit status (why the discipline exists)" {
  # The premise of the whole fix, driven against the real shell rather than cited.
  # If this ever stops being true, the `local _status=$?` / `return "$_status"`
  # pairing is no longer load-bearing and this file should say so.
  local script="$BATS_TEST_TMPDIR/mech.sh"
  printf 'set -euo pipefail\ncleanup() { false; }\ntrap cleanup EXIT\nexit 7\n' > "$script"
  run bash "$script"
  [ "$status" -eq 1 ] || { echo "expected the trap to clobber 7 -> 1, got $status"; return 1; }
  # And the discipline restores it.
  printf 'set -euo pipefail\ncleanup() { local s=$?; true; return "$s"; }\ntrap cleanup EXIT\nexit 7\n' > "$script"
  run bash "$script"
  [ "$status" -eq 7 ] || { echo "expected 7 to survive the trap, got $status"; return 1; }
}

# ── the runner resolver, proven rather than asserted ────────────────────────
# The check above replaced a line-at-a-time `*ubuntu*` grep that could be
# SATISFIED by a mixed matrix and was BLIND to a bracketed `runs-on:` (Bugbot
# Medium + LukasWodka on client#979). A replacement nobody has watched fail is
# just a different unwatched grep, so each shape from that review is planted
# here and driven through the SAME functions CI calls.

# Write a workflow fixture into its own directory and echo the directory.
_plant_wf() {
  local name="$1" dir="$BATS_TEST_TMPDIR/wf-$name"
  mkdir -p "$dir"
  cat > "$dir/planted.yaml"
  printf '%s\n' "$dir"
}

@test "the runner resolver EXPANDS a mixed matrix per element (the shape that satisfied the old check)" {
  local dir out
  dir="$(_plant_wf mixed <<'YAML'
jobs:
  pester:
    name: Pester
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: pwsh -c 1
  e2e-cluster:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-14]
    runs-on: ${{ matrix.os }}
    steps:
      - run: bash scripts/tests/e2e-cluster.sh
YAML
)"
  out="$(_wf_harness_runners "$dir/planted.yaml")"
  # The non-ubuntu leg is now a record of its own — the old extractor emitted the
  # whole `os: [...]` line, which contained `ubuntu` and therefore passed.
  case "$out" in *"e2e-cluster	RUNNER	macos-14"*) ;; *) echo "did not expand the mixed matrix to its macos leg: $out"; return 1 ;; esac
  case "$out" in *"e2e-cluster	RUNNER	ubuntu-latest"*) ;; *) echo "lost the ubuntu leg of the mixed matrix: $out"; return 1 ;; esac
  # And the Pester job's windows leg is NOT reported: it runs no harness, which
  # is why whole-workflow scoping had to give way to per-job scoping (that job's
  # `windows-latest` is legitimate and must not be able to fail this check).
  case "$out" in *"pester	"*) echo "reported a job that runs no e2e harness: $out"; return 1 ;; esac
  # The enforcement half must actually FAIL on it.
  run _check_ubuntu_runners "$dir"
  [ "$status" -ne 0 ] || { echo "a mixed ubuntu/macos e2e matrix PASSED the check: $output"; return 1; }
  case "$output" in *macos-14*) ;; *) echo "failed for the wrong reason: $output"; return 1 ;; esac
}

@test "the runner resolver SEES a bracketed runs-on: (the shape the old capture regex could not see at all)" {
  local dir out
  dir="$(_plant_wf bracket <<'YAML'
jobs:
  e2e-journey:
    runs-on: [self-hosted, macOS, arm64]
    steps:
      - run: bash scripts/tests/e2e-journey.sh
YAML
)"
  out="$(_wf_harness_runners "$dir/planted.yaml")"
  case "$out" in *"e2e-journey	RUNNER	macOS"*) ;; *) echo "did not see the bracketed runs-on list: $out"; return 1 ;; esac
  run _check_ubuntu_runners "$dir"
  [ "$status" -ne 0 ] || { echo "a bracketed self-hosted/macOS e2e runner PASSED the check: $output"; return 1; }
  # It reports the FIRST offending element (`self-hosted`) and stops, so accept
  # either name — but insist it names one of them rather than failing for some
  # unrelated reason, which is how a green-for-the-wrong-reason guard is born.
  case "$output" in *self-hosted*|*macOS*) ;; *) echo "failed for the wrong reason: $output"; return 1 ;; esac
}

@test "the runner resolver expands a BLOCK-form matrix list too" {
  local dir out
  dir="$(_plant_wf blocklist <<'YAML'
jobs:
  e2e-seal:
    strategy:
      matrix:
        os:
          - ubuntu-24.04
          - windows-2022
    runs-on: ${{ matrix.os }}
    steps:
      - run: bash scripts/tests/e2e-seal-check.sh
YAML
)"
  out="$(_wf_harness_runners "$dir/planted.yaml")"
  case "$out" in *"e2e-seal	RUNNER	windows-2022"*) ;; *) echo "did not expand the block-form matrix: $out"; return 1 ;; esac
  run _check_ubuntu_runners "$dir"
  [ "$status" -ne 0 ] || { echo "a block-form windows e2e leg PASSED the check: $output"; return 1; }
}

@test "a runner the resolver CANNOT read fails loudly instead of vanishing" {
  # The house rule, applied to this check's own empty case: 'could not determine'
  # must never be spelled the same way as 'determined it was ubuntu'. Each of
  # these three shapes produced NO output at all under the old extractor, so the
  # job was neither reported nor counted toward its vacuity floor.
  local dir shape
  for shape in unknown-key fromjson no-runs-on; do
    case "$shape" in
      unknown-key) dir="$(_plant_wf uk <<'YAML'
jobs:
  e2e-proxy:
    runs-on: ${{ matrix.runner }}
    steps:
      - run: bash scripts/tests/e2e-proxy.sh
YAML
)" ;;
      fromjson) dir="$(_plant_wf fj <<'YAML'
jobs:
  e2e-mysql:
    runs-on: ${{ fromJSON(needs.pick.outputs.r) }}
    steps:
      - run: bash scripts/tests/e2e-mysql.sh
YAML
)" ;;
      no-runs-on) dir="$(_plant_wf nr <<'YAML'
jobs:
  e2e-full-seal:
    steps:
      - run: bash scripts/tests/e2e-full-seal.sh
YAML
)" ;;
    esac
    run _wf_harness_runners "$dir/planted.yaml"
    case "$output" in *UNRESOLVED*) ;; *) echo "$shape was dropped silently rather than reported UNRESOLVED: $output"; return 1 ;; esac
    run _check_ubuntu_runners "$dir"
    [ "$status" -ne 0 ] || { echo "$shape PASSED the check while its runner was unknown: $output"; return 1; }
  done
}

@test "a workflow that invokes a harness but yields NO resolvable job fails the check" {
  # The per-workflow vacuity floor. A `jobs:` mapping the tracker cannot walk
  # (here: the invocation lives outside any job) must not read as 'all clean'.
  local dir
  dir="$(_plant_wf vacuous <<'YAML'
not-jobs:
  e2e-cluster:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/tests/e2e-cluster.sh
YAML
)"
  run _check_ubuntu_runners "$dir"
  [ "$status" -ne 0 ] || { echo "a workflow whose jobs could not be walked PASSED the check: $output"; return 1; }
  case "$output" in *vacuous*) ;; *) echo "failed for the wrong reason: $output"; return 1 ;; esac
}

@test "the runner resolver PASSES the real workflows, and a commented-out invocation conjures no job" {
  # The positive control: the shapes above must not be failing for a reason that
  # would also redden a legitimate tree. Plus the inverse of the census — a
  # commented invocation must not be counted as a covered harness.
  local dir out
  dir="$(_plant_wf ok <<'YAML'
jobs:
  e2e-cluster:
    strategy:
      matrix:
        os: [ubuntu-22.04, ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.os }}
    steps:
      - run: bash scripts/tests/e2e-cluster.sh
  e2e-journey:
    runs-on: [ubuntu-24.04]
    steps:
      - run: bash scripts/tests/e2e-journey.sh
  commented-out:
    runs-on: macos-14
    steps:
      # - run: bash scripts/tests/e2e-journey.sh
      - run: true
YAML
)"
  run _check_ubuntu_runners "$dir"
  [ "$status" -eq 0 ] || { echo "an all-ubuntu e2e matrix FAILED the check: $output"; return 1; }
  out="$(_wf_harness_runners "$dir/planted.yaml")"
  case "$out" in *"commented-out	"*) echo "a commented-out invocation was counted as a harness job: $out"; return 1 ;; esac
  # The bracketed form must resolve to the BARE label. Without the bracket strip
  # the entries read `[ubuntu-24.04]`, which fails the `ubuntu*` prefix test and
  # turns a legitimate single-element list into a false finding — so this is the
  # assertion that makes the bracket handling load-bearing in the PASSING
  # direction too, not only when it catches a macOS leg.
  case "$out" in *"e2e-journey	RUNNER	ubuntu-24.04"*) ;; *) echo "did not strip the brackets off a single-element runs-on list: $out"; return 1 ;; esac
  [ "$(printf '%s\n' "$out" | grep -c '	RUNNER	')" -eq 4 ] || { echo "expected 4 resolved runners, got: $out"; return 1; }
}
