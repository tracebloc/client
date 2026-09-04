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
  local f rc=0 seen=0
  while read -r f; do
    [ -n "$f" ] || continue
    _check_cleanup_engine_calls_bounded "$f" || rc=1
    seen=$(( seen + $(_count_cleanup_engine_calls "$f") ))
  done <<< "$(_harnesses)"
  [ "$rc" -eq 0 ] || return 1
  # The census for THIS check: with the cluster reap extracted, the remaining
  # engine calls in these traps are e2e-proxy's squid removal. If the extraction
  # ever finds zero, the loop above is asserting nothing and must not read green.
  [ "$seen" -ge 1 ] || {
    echo "inspected 0 docker/k3d call(s) across the harness cleanups — the extraction went vacuous"
    return 1
  }
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

@test "every workflow job that runs an e2e harness is on an ubuntu runner (so _bounded really bounds)" {
  local wf line jobs_seen=0 h
  for wf in "$REPO"/.github/workflows/*.yaml "$REPO"/.github/workflows/*.yml; do
    [ -f "$wf" ] || continue
    grep -qE 'bash scripts/tests/e2e-[a-z-]+\.sh' "$wf" || continue
    # Every runner this workflow declares, matrix values included. Scoping to the
    # exact job would need a YAML parser; asserting it for the WHOLE workflow is
    # strictly stronger and needs none.
    while read -r line; do
      [ -n "$line" ] || continue
      jobs_seen=$((jobs_seen + 1))
      case "$line" in
        *ubuntu*) ;;
        *) echo "$wf runs an e2e harness but declares a non-ubuntu runner: $line — _bounded is a NO-OP without coreutils timeout(1), so the client#979 bound would not exist there"; return 1 ;;
      esac
    done <<< "$(grep -hoE '(runs-on:[[:space:]]*[A-Za-z0-9._-]+|os:[[:space:]]*\[[^]]*\])' "$wf" \
                 | grep -vE 'runs-on:[[:space:]]*\$\{\{')"
  done
  [ "$jobs_seen" -ge 4 ] || {
    echo "found only $jobs_seen runner declaration(s) across the harness workflows — the scan went vacuous, so this test would pass while asserting nothing"
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
  local dir="$BATS_TEST_TMPDIR/nearmiss" late="$dir/e2e-late.sh" early="$dir/e2e-early.sh"
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
