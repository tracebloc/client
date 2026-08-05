#!/usr/bin/env bats
# Tests for scripts/lib/common.sh — config validation, the install_cleanup
# CLIENT_STATE guard (#716), retry, has.
# 1.7.0, not 1.5.0: `run -<code>` landed in 1.5.0 but bats_require_minimum_version
# itself only exists from 1.7.0, so a 1.5.x-1.6.x bats would die on THIS line
# before the guard could help. 1.7.0 is the real floor. (Saqlain review, #443.)
bats_require_minimum_version 1.7.0
load test_helper

setup() {
  load_lib
}

# ── validate_config ────────────────────────────────────────────────────────
@test "validate_config: valid config passes" {
  # cd -P like the tilde tests below: macOS puts BATS_TEST_TMPDIR under the
  # /var -> /private/var symlink, and validate_config resolves the dir via
  # `cd -P` — an unresolved $HOME would spuriously fail the under-$HOME check.
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1
  HOST_DATA_DIR="$HOME/.tracebloc"
  run validate_config
  [ "$status" -eq 0 ] || return 1
}

@test "validate_config: empty HOST_DATA_DIR fails closed (#384 bugbot)" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR=""
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"must not be empty"* ]] || return 1
}

@test "validate_config: leading tilde in HOST_DATA_DIR expands to \$HOME (#384 bugbot)" {
  # Resolve symlinks in HOME so macOS's /var->/private/var (via validate_config's
  # `cd -P`) doesn't skew the under-$HOME check — this keeps the test about tilde
  # expansion, not the tmpdir's symlink shape.
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR="~/tracebloc-new"
  run validate_config
  # Pre-fix, `~/x` became the literal "$HOME/~/x" and failed parent resolution;
  # now it resolves to $HOME/tracebloc-new and validates. No `~` may survive.
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"~"* ]] || return 1
}

@test "validate_config: HOST_DATA_DIR == \$HOME is rejected, not adopted (#384 bugbot)" {
  # $HOME itself must never be the data dir: the installer would chmod 777
  # home-level dirs, bind-mount all of $HOME, and treat ~/data|~/mysql as data.
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not \$HOME itself"* ]] || return 1
}

@test "validate_config: bare ~ is rejected (resolves to \$HOME) (#384 bugbot)" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR="~"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not \$HOME itself"* ]] || return 1
}

@test "validate_config: invalid CLUSTER_NAME -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME="1nope"; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/x"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"CLUSTER_NAME"* ]] || return 1
}

@test "validate_config: invalid SERVERS -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=ok; SERVERS=0; AGENTS=1; HOST_DATA_DIR="$HOME/x"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"SERVERS"* ]] || return 1
}

@test "validate_config: HOST_DATA_DIR outside HOME -> error" {
  HOME="$BATS_TEST_TMPDIR"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="/tmp/not-under-home-$$"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"HOST_DATA_DIR"* ]] || return 1
}

# ── validate_config: HOST_DATASET_DIR (backend#743) ──────────────────────────
# Resolve HOME to its physical path so the HOST_DATA_DIR under-$HOME check (which
# uses cd -P) is not tripped by macOS's /var -> /private/var symlink (Linux/CI
# has none). The dataset dir itself MAY live outside $HOME — that's the point.
@test "validate_config: HOST_DATASET_DIR outside HOME but existing+writable -> passes" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/dataset-mount"; mkdir -p "$HOST_DATASET_DIR"
  run validate_config
  [ "$status" -eq 0 ] || return 1
}

@test "validate_config: HOST_DATASET_DIR does not exist -> error (never mkdir a share root)" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/nope-$$"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"does not exist"* ]] || return 1
}

@test "validate_config: HOST_DATASET_DIR not writable -> error" {
  [[ "$(id -u)" -eq 0 ]] && skip "root bypasses filesystem permission bits"
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  HOST_DATASET_DIR="$HOME/ro-mount"; mkdir -p "$HOST_DATASET_DIR"; chmod 555 "$HOST_DATASET_DIR"
  run validate_config
  chmod 755 "$HOST_DATASET_DIR"   # restore so bats can clean up the tmpdir
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not writable"* ]] || return 1
}

@test "validate_config: HOST_DATA_DIR still rejected outside HOME when dataset dir is set" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="/tmp/not-under-home-$$"
  HOST_DATASET_DIR="$HOME/dataset-mount"; mkdir -p "$HOST_DATASET_DIR"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"HOST_DATA_DIR"* ]] || return 1
}

@test "validate_config: node-local + HOST_DATASET_DIR -> error (unsupported combo)" {
  HOME="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"; USER=tester
  CLUSTER_NAME=ok; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$HOME/.tracebloc"
  TB_STORAGE_MODE=node-local
  HOST_DATASET_DIR="$HOME/dataset-mount"; mkdir -p "$HOST_DATASET_DIR"
  run validate_config
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"HOST_DATASET_DIR is not supported with TB_STORAGE_MODE=node-local"* ]] || return 1
}

# ── C1 single-node guarantee (RFC-0003 Option C, load-time) ─────────────────
# The C1 clamp runs when common.sh is sourced, reading AGENTS/SERVERS from env.
# Source in a fresh shell (not the test's, which already has common.sh's readonly
# vars) with the env applied, then print the clamped values.
@test "C1: node-local forces single-node — AGENTS=0 AND SERVERS=1" {
  run env TB_STORAGE_MODE=node-local AGENTS=4 SERVERS=3 \
    bash -c "source '${LIB_DIR}/common.sh' >/dev/null 2>&1; echo \"\$AGENTS \$SERVERS\""
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "0 1" ] || return 1
}

@test "C1: hostpath (default) leaves AGENTS/SERVERS untouched" {
  run env TB_STORAGE_MODE=hostpath AGENTS=4 SERVERS=3 \
    bash -c "source '${LIB_DIR}/common.sh' >/dev/null 2>&1; echo \"\$AGENTS \$SERVERS\""
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "4 3" ] || return 1
}

# ── install_cleanup: the CLIENT_STATE guard (#716) ─────────────────────────
@test "install_cleanup: exit 0 -> silent" {
  out="$( ( exit 0 ); install_cleanup 2>&1 )"
  [[ "$out" != *"did not complete"* ]] || return 1
}

@test "install_cleanup: failure + CLIENT_STATE set -> suppresses generic message" {
  CLIENT_STATE=connected
  out="$( ( exit 1 ); install_cleanup 2>&1 )"
  [[ "$out" != *"did not complete"* ]] || return 1
}

@test "install_cleanup: failure + CLIENT_STATE unset -> shows generic message" {
  unset CLIENT_STATE
  out="$( ( exit 1 ); install_cleanup 2>&1 )"
  [[ "$out" == *"did not complete"* ]] || return 1
}

@test "install_cleanup: exit 2 -> re-run hint" {
  unset CLIENT_STATE
  out="$( ( exit 2 ); install_cleanup 2>&1 )"
  [[ "$out" == *"Re-run required"* || "$out" == *"Complete the step"* ]] || return 1
}

# ── retry ──────────────────────────────────────────────────────────────────
@test "retry: succeeds on first attempt" {
  run retry 3 1 true
  [ "$status" -eq 0 ] || return 1
}

@test "retry: gives up after max attempts" {
  run retry 2 0 false
  [ "$status" -ne 0 ] || return 1
}

@test "retry: succeeds after a transient failure" {
  marker="$BATS_TEST_TMPDIR/m"
  flaky() { if [ -f "$marker" ]; then return 0; fi; touch "$marker"; return 1; }
  run retry 3 0 flaky
  [ "$status" -eq 0 ] || return 1
}

# ── curl_secure (backend#1252) ─────────────────────────────────────────────
# The TLS floor used to be a bare constant every call site had to splice in by
# hand, and seven had silently lost it — one of them the POST that carries the
# client's password. These pin the wrapper's contract so it can't drift back:
# the floor is always present, a caller can still TIGHTEN a bound, and a
# stall-bounded transfer keeps having no overall deadline.
@test "curl_secure: always passes the minimum TLS version, caller args intact" {
  curl() { printf '%s' "$*"; }
  run curl_secure -fsSL https://example.com
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"--tlsv1.2"* ]] || return 1
  [[ "$output" == *"-fsSL https://example.com"* ]] || return 1
}

@test "curl_secure: supplies default time bounds when the caller sets none" {
  curl() { printf '%s' "$*"; }
  run curl_secure -fsSL https://example.com
  [[ "$output" == *"--connect-timeout 30"* ]] || return 1
  [[ "$output" == *"--max-time 300"* ]] || return 1
}

@test "curl_secure: a caller's own deadline wins (lands after the default)" {
  curl() { printf '%s' "$*"; }
  run curl_secure -sS -m 60 https://example.com
  # curl honours the LAST occurrence, so -m 60 must come after --max-time 300.
  [[ "$output" == *"--max-time 300"*"-m 60"* ]] || return 1
}

@test "curl_secure: a stall-bounded transfer gets NO overall deadline" {
  # download_with_progress / the k3d + kubectl binaries bound themselves with
  # --speed-limit/--speed-time on purpose: a hard --max-time would fail a
  # slow-but-healthy link on a big download. The wrapper must not add one.
  curl() { printf '%s' "$*"; }
  run curl_secure -fSL --speed-limit 1024 --speed-time 60 -o /tmp/x https://example.com
  [[ "$output" == *"--tlsv1.2"* ]] || return 1
  [[ "$output" != *"--max-time"* ]] || return 1
}

@test "curl_secure: default bounds are overridable by env" {
  curl() { printf '%s' "$*"; }
  TB_CURL_CONNECT_TIMEOUT=5
  TB_CURL_MAX_TIME=7
  run curl_secure https://example.com
  [[ "$output" == *"--connect-timeout 5"* ]] || return 1
  [[ "$output" == *"--max-time 7"* ]] || return 1
}

@test "curl_secure: dispatches through curl, so the suite can still mock it" {
  # Deliberately NOT `command curl` — every mocked-transfer test in this suite
  # substitutes a curl shell function, which `command` would bypass.
  curl() { return 42; }
  run curl_secure https://example.com
  [ "$status" -eq 42 ] || return 1
}

@test "curl_secure: CURL_SECURE stays defined for out-of-tree callers" {
  [ "$CURL_SECURE" = "--tlsv1.2" ] || return 1
}

# ── has ────────────────────────────────────────────────────────────────────
@test "has: present command" { run has bash; [ "$status" -eq 0 ] || return 1; }
@test "has: absent command" { run has nope-not-a-real-cmd-xyz; [ "$status" -ne 0 ] || return 1; }

# ── count_bar (first-run: honest N-of-M for multi-image pulls) ───────────────
@test "count_bar: renders 'N of M <noun>'" {
  run count_bar 3 6 services
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"3 of 6 services"* ]] || return 1
}

@test "count_bar: clamps current above total (never over-reports)" {
  run count_bar 9 6 services
  [[ "$output" == *"6 of 6 services"* ]] || return 1
  [[ "$output" != *"9 of 6"* ]] || return 1
}

@test "count_bar: non-numeric current -> 0 (no crash)" {
  run count_bar nope 6 services
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"0 of 6 services"* ]] || return 1
}

@test "count_bar: total<1 floored to 1 (no divide-by-zero)" {
  run count_bar 0 0 services
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"0 of 1 services"* ]] || return 1
}

# ── step_header (first-run: bold a–f running headers) ────────────────────────
@test "step_header: renders '<letter>) <Title>'" {
  run step_header a "Checking your machine"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"a) Checking your machine"* ]] || return 1
}

# ── print_roadmap (the '2. Installing' a–f plan) ─────────────────────────────
@test "print_roadmap: lists the a–f plan under '2. Installing'" {
  run print_roadmap
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"2. Installing"* ]] || return 1
  [[ "$output" == *"a) Check your machine"* ]] || return 1
  [[ "$output" == *"b) Install what tracebloc needs"* ]] || return 1
  [[ "$output" == *"c) Create your secure environment"* ]] || return 1
  [[ "$output" == *"d) Register this machine"* ]] || return 1
  [[ "$output" == *"e) Install tracebloc"* ]] || return 1
  [[ "$output" == *"f) Connect to the tracebloc network"* ]] || return 1
}

# ── print_banner (title + version; suppressed after the bootstrap drew it) ───
@test "print_banner: title + version when TB_VERSION is set" {
  unset TRACEBLOC_BANNER_SHOWN
  TB_VERSION="v1.9.3"; OS=Darwin; ARCH=arm64
  CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1; HOST_DATA_DIR="$BATS_TEST_TMPDIR/.tracebloc"
  run print_banner
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Setting up"* ]] || return 1
  [[ "$output" == *"tracebloc"* ]] || return 1
  [[ "$output" == *"v1.9.3"* ]] || return 1
}

@test "print_banner: suppressed when the bootstrap already drew it (TRACEBLOC_BANNER_SHOWN)" {
  export TRACEBLOC_BANNER_SHOWN=1
  OS=Darwin; ARCH=arm64; CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/.tracebloc"
  run print_banner
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Setting up"* ]] || return 1
  unset TRACEBLOC_BANNER_SHOWN
}

# ── Root-aware sudo + preflight (RFC 0001 A2) ────────────────────────────────
# _have_sudo_bin / _real_sudo are stubbed so every branch runs without a real
# sudo; the payload command is a recordable mock so the root path never shells
# out to a real binary.
@test "sudo(): as root, runs the command directly — no real sudo" {
  MOCK_CALLS="$(mktemp)"
  id() { echo 0; }
  modprobe() { record "modprobe $*"; }
  _real_sudo() { record "real_sudo $*"; }
  run sudo modprobe overlay
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "modprobe overlay"
  ! mock_calls | grep -q "real_sudo" || return 1
}

@test "sudo(): non-root with sudo present defers to the real sudo" {
  MOCK_CALLS="$(mktemp)"
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "real_sudo $*"; }
  run sudo modprobe overlay
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "real_sudo modprobe overlay"
}

@test "sudo(): non-root without sudo returns 127 (best-effort friendly), never exits" {
  id() { echo 1000; }
  _have_sudo_bin() { return 1; }
  # `run -127` makes bats assert the 127 itself and fail the test at this line on
  # any other code, so a following [ "$status" -eq 127 ] would be unreachable.
  run -127 sudo modprobe overlay
}

@test "preflight_sudo: root returns 0 with no sudo binary needed" {
  id() { echo 0; }
  _have_sudo_bin() { return 1; }   # even with NO sudo, root is fine
  _real_sudo() { echo "must-not-run"; return 1; }
  run preflight_sudo
  [ "$status" -eq 0 ] || return 1
}

@test "preflight_sudo: non-root + no sudo => accurate error, not 'no sudo access'" {
  id() { echo 1000; }
  _have_sudo_bin() { return 1; }
  run preflight_sudo
  [ "$status" -ne 0 ] || return 1
  printf '%s\n' "$output" | grep -qF "isn't installed"
}

@test "preflight_sudo: non-root + passwordless sudo returns 0 (no prompt)" {
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { case "$*" in "-n true") return 0 ;; *) return 1 ;; esac; }
  run preflight_sudo
  [ "$status" -eq 0 ] || return 1
}

@test "sudo(): exported so a bash -c subshell inherits the shadow (#372)" {
  # The nested `sudo <cmd>` in setup-linux.sh's bash -c blocks (apt-lock wait,
  # RHEL-rebuild Docker install) must route through OUR shadow, not the real sudo.
  # A child bash sees the function only if it was exported (export -f in common.sh).
  run bash -c 'declare -F sudo >/dev/null && declare -f sudo | grep -q _real_sudo && echo INHERITED'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"INHERITED"* ]] || return 1
}

@test "_have_sudo_bin: set -e safe when sudo is absent (no command substitution, #372)" {
  # The pre-fix body wrapped `type -P sudo` in `[ -n "$(...)" ]`. On bash <4.4
  # (Amazon Linux 2's 4.2, and this dev host's 3.2) a failing command
  # substitution trips `set -e` EVEN inside an `if` condition, so the non-root/
  # no-sudo path aborted before preflight_sudo could print its clear message.
  # The whole-body `type -P` form has no substitution and must survive.
  run bash -c "set -e; PATH=/nonexistent; $(declare -f _have_sudo_bin); if _have_sudo_bin; then echo yes; else echo no; fi; echo survived"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"no"* ]] || return 1
  [[ "$output" == *"survived"* ]] || return 1
}

# ── spin deadline + spin_cmd_bounded (#426) ──────────────────────────────────
@test "spin: optional deadline kills a stuck pid and returns 124 (#426)" {
  sleep 30 &
  local stuck_pid=$!
  run spin "$stuck_pid" "waiting…" 1
  [ "$status" -eq 124 ] || return 1
  # the stuck process is gone (kill -0 fails)
  ! kill -0 "$stuck_pid" 2>/dev/null || return 1
}

@test "spin: deadline kills the wrapper's CHILDREN too, not just the subshell (Bugbot #442)" {
  # `; true` stops bash exec-optimizing the subshell away, forcing the real
  # wrapper+child shape cluster.sh's `( k3d … ) &` can produce.
  ( sleep 30; true ) &
  local wrapper=$!
  sleep 0.3                                  # let the subshell fork its child
  local child
  child="$(pgrep -P "$wrapper" | head -1)"
  [ -n "$child" ] || return 1
  run spin "$wrapper" "waiting…" 1
  [ "$status" -eq 124 ] || return 1
  ! kill -0 "$wrapper" 2>/dev/null || return 1
  ! kill -0 "$child" 2>/dev/null || return 1
}

@test "spin: deadline KILLs a TERM-immune child even after the wrapper died (Bugbot #442 r2)" {
  # The child ignores TERM; the wrapper dies at TERM, reparenting the child to
  # init — only a KILL by captured PID can still reach it.
  ( bash -c 'trap "" TERM; sleep 30'; true ) &
  local wrapper=$!
  sleep 0.4
  local child
  child="$(pgrep -P "$wrapper" | head -1)"
  [ -n "$child" ] || return 1
  run spin "$wrapper" "waiting…" 1
  [ "$status" -eq 124 ] || return 1
  ! kill -0 "$child" 2>/dev/null || return 1
}

@test "tb_minutes_or: base-10 normalization defuses the octal trap (Bugbot #442 r6)" {
  [ "$(tb_minutes_or 08 15)" = "8" ] || return 1      # would abort $(( )) as invalid octal
  [ "$(tb_minutes_or 010 15)" = "10" ] || return 1    # would silently read as 8
  [ "$(tb_minutes_or 25 15)" = "25" ] || return 1
  [ "$(tb_minutes_or '' 15)" = "15" ] || return 1
  [ "$(tb_minutes_or 20m 15)" = "15" ] || return 1
}

@test "spin: deadline path survives set -e end-to-end (Bugbot #442 r3)" {
  # A childless stuck pid (pkill -P finds nothing -> returns 1) plus wait
  # after a kill: under `set -e` any bare failure aborts the deadline path
  # before `return 124` and the caller sees 143/1 — no timeout copy, no
  # partial-cluster cleanup. The whole path must still deliver 124.
  run bash -c "set -euo pipefail; source '${BATS_TEST_DIRNAME}/../lib/common.sh'; LOG_FILE=/dev/null; sleep 30 & spin \$! 'waiting…' 1"
  [ "$status" -eq 124 ] || return 1
}

@test "spin: without a deadline behaviour is unchanged (returns the pid's rc)" {
  # Called directly (not via `run`): spin must `wait` the pid, and a `run`
  # subshell can't wait a process it didn't spawn.
  bash -c 'exit 7' &
  local rc=0
  spin "$!" "quick…" >/dev/null || rc=$?
  [ "$rc" -eq 7 ] || return 1
}

@test "spin_cmd_bounded: fast success passes through rc 0, no output" {
  run spin_cmd_bounded 5 "quick…" true
  [ "$status" -eq 0 ] || return 1
}

@test "spin_cmd_bounded: failure preserves the command's exit code + tails the log" {
  LOG_FILE="$BATS_TEST_TMPDIR/spin.log"   # load_lib pins LOG_FILE=/dev/null; tail needs a real file
  run spin_cmd_bounded 5 "failing…" bash -c 'echo boom; exit 3'
  [ "$status" -eq 3 ] || return 1
  [[ "$output" == *"Last 10 lines of log:"* ]] || return 1
  [[ "$output" == *"boom"* ]] || return 1
}

@test "spin_cmd_bounded: deadline -> 124 with an explicit timeout note" {
  run spin_cmd_bounded 1 "stuck…" sleep 30
  [ "$status" -eq 124 ] || return 1
  [[ "$output" == *"timed out after 1s"* ]] || return 1
}

# ── assert_tool_runs (execute-gate, #411) ────────────────────────────────────
@test "assert_tool_runs: a working tool passes, binary untouched (#411)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "k3d version v5.9.0"\n' > "$BATS_TEST_TMPDIR/bin/k3d"
  chmod +x "$BATS_TEST_TMPDIR/bin/k3d"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run assert_tool_runs k3d version
  [ "$status" -eq 0 ] || return 1
  [ -f "$BATS_TEST_TMPDIR/bin/k3d" ] || return 1
}

@test "assert_tool_runs: a broken tool with --rm errors and removes the binary WE placed (#411)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/k3d"
  chmod +x "$BATS_TEST_TMPDIR/bin/k3d"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run assert_tool_runs --rm "$BATS_TEST_TMPDIR/bin/k3d" k3d version
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"won't run"* ]] || return 1
  [ ! -f "$BATS_TEST_TMPDIR/bin/k3d" ] || return 1        # the binary we placed was removed
}

@test "assert_tool_runs: a broken tool WITHOUT --rm errors but leaves the binary (#411 review)" {
  # Already-present / pkg-managed path: we didn't place it, so we must not delete it
  # (deleting a brew symlink just wedges the re-run — reviewer).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/k3d"
  chmod +x "$BATS_TEST_TMPDIR/bin/k3d"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run assert_tool_runs k3d version
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"won't run"* ]] || return 1
  [ -f "$BATS_TEST_TMPDIR/bin/k3d" ] || return 1          # NOT removed — we didn't place it
}

@test "assert_tool_runs: --rm removes ONLY the binary that actually ran, not a decoy copy (#411 Bugbot)" {
  # The failing k3d resolves to bin/; --rm points at a different (installer-dir)
  # copy that did NOT run. The -ef guard must leave that copy alone.
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/tools"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/k3d"; chmod +x "$BATS_TEST_TMPDIR/bin/k3d"
  : > "$BATS_TEST_TMPDIR/tools/k3d"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run assert_tool_runs --rm "$BATS_TEST_TMPDIR/tools/k3d" k3d version
  [ "$status" -ne 0 ] || return 1
  [ -f "$BATS_TEST_TMPDIR/tools/k3d" ] || return 1         # NOT removed — it isn't the binary that ran
}

# ── setup_log_file / _choose_log_file temp fallback (#432 prepare-host residual) ──
@test "_choose_log_file: writable HOST_DATA_DIR -> a path under it" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"
  run _choose_log_file
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == "$HOST_DATA_DIR"* ]] || return 1
  [ -f "$output" ] || return 1
}
@test "_choose_log_file: uncreatable HOST_DATA_DIR -> temp fallback, never a bare failure (#432)" {
  ro="$BATS_TEST_TMPDIR/ro"; mkdir -p "$ro"; chmod 500 "$ro"
  HOST_DATA_DIR="$ro/cannot/make"
  run _choose_log_file
  chmod 700 "$ro"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *tracebloc-install-* ]] || return 1
}

# ── _assert_download_size (resilient tool download, #607) ────────────────────
# Catches a proxy/AV-truncated or blocked binary transfer as a TRANSFER failure,
# before _verify_sha256 misreports it as a checksum ("tampering") failure.
@test "_assert_download_size: a complete file above the floor passes" {
  local f="$BATS_TEST_TMPDIR/big.bin"; head -c 1200000 /dev/zero > "$f"
  run _assert_download_size "$f" 1000000 "kubectl"
  [ "$status" -eq 0 ] || return 1
}

@test "_assert_download_size: a truncated/blocked payload fails with a transfer message" {
  local f="$BATS_TEST_TMPDIR/tiny.html"; printf '<html>blocked by proxy</html>' > "$f"
  run _assert_download_size "$f" 1000000 "k3d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"truncated or blocked"* ]] || return 1
  [[ "$output" == *"proxy or antivirus"* ]] || return 1
}

@test "_assert_download_size: a missing file fails closed" {
  run _assert_download_size "$BATS_TEST_TMPDIR/nope.bin" 100 "helm"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"truncated or blocked"* ]] || return 1
}

@test "_assert_download_size: TB_MIN_DOWNLOAD_BYTES=0 relaxes the floor (bats fetch-mock hook)" {
  export TB_MIN_DOWNLOAD_BYTES=0
  local f="$BATS_TEST_TMPDIR/small.bin"; printf 'x' > "$f"
  run _assert_download_size "$f" 1000000 "k3d"
  [ "$status" -eq 0 ] || return 1
}
