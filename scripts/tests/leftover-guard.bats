#!/usr/bin/env bats
# Tests for the installer leftover-data guard in scripts/lib/cluster.sh
# (RFC-0003 §4 / D3, #376): a new install must never silently adopt data left
# behind by an earlier install. Covers detection across both on-disk layouts
# (flat + per-release), the reuse/wipe/new-dir choices, and the fail-safe abort
# when there is no terminal and no explicit action.
load test_helper

setup() {
  load_lib cluster.sh
  # A self-contained $HOME so HOST_DATA_DIR passes validate_config's
  # "must be under $HOME" rule and nothing outside the tmp tree is ever touched.
  HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  HOST_DATA_DIR="$HOME/.tracebloc"
  unset TB_LEFTOVER_ACTION TB_STORAGE_MODE HOST_DATASET_DIR TRACEBLOC_SKIP_LEFTOVER_GUARD
  TB_TTY=/dev/null   # readable but empty; individual tests override as needed
}

# Seed a MySQL data file in the flat layout ($HOST_DATA_DIR/mysql).
seed_flat_mysql() { mkdir -p "$HOST_DATA_DIR/mysql"; : >"$HOST_DATA_DIR/mysql/ibdata1"; }
# Seed a dataset file in the per-release layout ($HOST_DATA_DIR/<rel>/data).
seed_release_data() { mkdir -p "$HOST_DATA_DIR/tracebloc/data/ds1"; : >"$HOST_DATA_DIR/tracebloc/data/ds1/rows.csv"; }

# ── _leftover_data_dirs (detection) ──────────────────────────────────────────
@test "_leftover_data_dirs: nonexistent HOST_DATA_DIR -> nothing" {
  run _leftover_data_dirs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_leftover_data_dirs: empty dirs / values.yaml / log are not data" {
  mkdir -p "$HOST_DATA_DIR/mysql" "$HOST_DATA_DIR/logs"      # empty subdirs
  : >"$HOST_DATA_DIR/values.yaml"
  : >"$HOST_DATA_DIR/install-20260101-000000.log"
  run _leftover_data_dirs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_leftover_data_dirs: flat mysql data detected" {
  seed_flat_mysql
  run _leftover_data_dirs
  [[ "$output" == *"$HOST_DATA_DIR/mysql"* ]]
}

@test "_leftover_data_dirs: per-release layout detected" {
  seed_release_data
  run _leftover_data_dirs
  [[ "$output" == *"$HOST_DATA_DIR/tracebloc/data"* ]]
}

@test "_leftover_data_dirs: unreadable (root/container-owned) dir is detected, not skipped (#384 bugbot)" {
  [ "$(id -u)" -eq 0 ] && skip "cannot make a dir unreadable as root"
  mkdir -p "$HOST_DATA_DIR/mysql"; : >"$HOST_DATA_DIR/mysql/ibdata1"
  chmod 000 "$HOST_DATA_DIR/mysql"            # host user can't list it (find errors)
  run _leftover_data_dirs
  chmod 755 "$HOST_DATA_DIR/mysql"            # restore for teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOST_DATA_DIR/mysql"* ]] # detected via find's error, not skipped
}

@test "_leftover_data_dirs: readable dir with an unreadable subdir is detected (#384 bugbot)" {
  [ "$(id -u)" -eq 0 ] && skip "cannot make a dir unreadable as root"
  mkdir -p "$HOST_DATA_DIR/mysql/sub"; : >"$HOST_DATA_DIR/mysql/sub/secret"
  chmod 000 "$HOST_DATA_DIR/mysql/sub"        # top readable, subdir not -> find errors
  run _leftover_data_dirs
  chmod 755 "$HOST_DATA_DIR/mysql/sub"        # restore for teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOST_DATA_DIR/mysql"* ]]
}

@test "_leftover_data_dirs: large multi-file MySQL dir detected under pipefail (#384 bugbot)" {
  # A real MySQL data dir has many files; once find's output exceeds the pipe
  # buffer a find|head|grep pipeline SIGPIPEs find, and under `set -o pipefail`
  # (which the installer sets) that wrongly reads as "empty" -> silent adopt.
  mkdir -p "$HOST_DATA_DIR/mysql"
  for i in $(seq 1 3000); do : >"$HOST_DATA_DIR/mysql/table_with_a_reasonably_long_name_$i.ibd"; done
  set -o pipefail
  run _leftover_data_dirs
  set +o pipefail
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOST_DATA_DIR/mysql"* ]]
}

# ── guard_leftover_data (decision) ───────────────────────────────────────────
@test "guard: clean slate -> proceeds silently" {
  run guard_leftover_data
  [ "$status" -eq 0 ]
}

@test "guard: TRACEBLOC_SKIP_LEFTOVER_GUARD bypasses even with data present" {
  seed_flat_mysql
  TRACEBLOC_SKIP_LEFTOVER_GUARD=1 run guard_leftover_data
  [ "$status" -eq 0 ]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]   # untouched
}

@test "guard: --reuse-data (TB_LEFTOVER_ACTION=reuse) keeps the data and proceeds" {
  seed_flat_mysql
  TB_LEFTOVER_ACTION=reuse guard_leftover_data
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]   # kept
}

@test "guard: --wipe-data (TB_LEFTOVER_ACTION=wipe) removes the detected data dirs" {
  seed_flat_mysql
  seed_release_data
  TB_LEFTOVER_ACTION=wipe guard_leftover_data
  [ ! -e "$HOST_DATA_DIR/mysql/ibdata1" ]
  [ ! -e "$HOST_DATA_DIR/tracebloc/data/ds1/rows.csv" ]
}

@test "_wipe_leftover_data: refuses when HOST_DATA_DIR is empty (#384 wipe-safety)" {
  HOST_DATA_DIR=""
  run _wipe_leftover_data "/some/path/mysql"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to wipe"* ]]
}

@test "_wipe_leftover_data: refuses when HOST_DATA_DIR is outside \$HOME (#384 wipe-safety)" {
  HOST_DATA_DIR="/var/tmp/evil"
  run _wipe_leftover_data "/var/tmp/evil/mysql"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to wipe"* ]]
}

@test "guard: wipe that cannot remove data fails closed, does not adopt (#384 bugbot)" {
  [ "$(id -u)" -eq 0 ] && skip "rm cannot be blocked as root"
  seed_flat_mysql
  chmod a-w "$HOST_DATA_DIR/mysql"            # make ibdata1 unremovable
  TB_LEFTOVER_ACTION=wipe TB_TTY=/dev/null run guard_leftover_data
  chmod u+w "$HOST_DATA_DIR/mysql"            # restore so teardown can clean up
  [ "$status" -eq 1 ]                          # aborted, did not proceed
  [[ "$output" == *"Could not fully wipe"* ]]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]        # survivor NOT silently adopted
}

@test "_leftover_data_dirs: symlinked subdir is not a wipeable candidate (#384 bugbot)" {
  mkdir -p "$HOST_DATA_DIR"
  local target="$BATS_TEST_TMPDIR/outside"; mkdir -p "$target/mysql"; : >"$target/mysql/ibdata1"
  ln -s "$target" "$HOST_DATA_DIR/evil"       # $HOST_DATA_DIR/evil -> outside the data dir
  run _leftover_data_dirs
  [ "$status" -eq 0 ]
  [[ "$output" != *"/evil/"* ]]               # symlink not walked into a candidate
}

@test "_wipe_leftover_data: refuses to delete a symlink, target preserved (#384 bugbot)" {
  mkdir -p "$HOST_DATA_DIR"
  local target="$BATS_TEST_TMPDIR/outside"; mkdir -p "$target"; : >"$target/keep"
  ln -s "$target" "$HOST_DATA_DIR/link"
  run _wipe_leftover_data "$HOST_DATA_DIR/link"
  [ "$status" -ne 0 ]
  [ -e "$target/keep" ]                        # target outside HOST_DATA_DIR untouched
  [ -L "$HOST_DATA_DIR/link" ]                  # symlink itself left for the user
}

@test "guard: wipe never touches HOST_DATASET_DIR (shared mount)" {
  seed_flat_mysql
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/netmount"
  mkdir -p "$HOST_DATASET_DIR/data"; : >"$HOST_DATASET_DIR/data/keep.csv"
  TB_LEFTOVER_ACTION=wipe guard_leftover_data
  [ ! -e "$HOST_DATA_DIR/mysql/ibdata1" ]     # local data wiped
  [ -e "$HOST_DATASET_DIR/data/keep.csv" ]    # network mount preserved
}

@test "guard: no terminal + no action -> fail-safe abort (exit 1, data untouched)" {
  seed_flat_mysql
  TB_TTY=/no/such/tty run guard_leftover_data
  [ "$status" -eq 1 ]
  [[ "$output" == *"no choice was given"* ]]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]   # abort leaves data as-is
}

@test "guard: readable-but-unopenable TB_TTY -> non-interactive guidance, not generic abort (#384 bugbot)" {
  # /dev/tty is world-readable (-r true) yet cannot be OPENED without a
  # controlling terminal — the CI / curl|bash case. A plain `-r` check would take
  # the interactive branch, `read` would fail, and the guard would abort with the
  # generic text instead of the actionable --reuse-data/--wipe-data guidance.
  # Only meaningful where /dev/tty is unopenable; skip in an interactive shell.
  [[ -r /dev/tty ]] || skip "/dev/tty not readable in this environment"
  { : </dev/tty; } 2>/dev/null && skip "/dev/tty is openable here (interactive shell)"
  seed_flat_mysql
  TB_TTY=/dev/tty run guard_leftover_data
  [ "$status" -eq 1 ]
  [[ "$output" == *"no choice was given"* ]]   # non-interactive guidance, not generic abort
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]          # fail-safe: data untouched
}

# ── interactive prompt (input fed via TB_TTY=/dev/stdin) ─────────────────────
@test "guard: interactive 'w' wipes" {
  seed_flat_mysql
  TB_TTY=/dev/stdin run guard_leftover_data <<< "w"
  [ "$status" -eq 0 ]
  [ ! -e "$HOST_DATA_DIR/mysql/ibdata1" ]
}

@test "guard: interactive 'a' (and unrecognised input) aborts" {
  seed_flat_mysql
  TB_TTY=/dev/stdin run guard_leftover_data <<< "a"
  [ "$status" -eq 1 ]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]
}

@test "guard: interactive default (empty input) aborts" {
  seed_flat_mysql
  TB_TTY=/dev/stdin run guard_leftover_data <<< ""
  [ "$status" -eq 1 ]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]
}

# ── input sanitizing (#384 bugbot: paste garbage + whitespace) ───────────────
@test "_read_sanitized: strips CSI/paste garbage and trims whitespace" {
  TB_TTY=/dev/stdin
  local got="unset"
  _read_sanitized "" got <<< "$(printf ' \033[Dhello world ')"
  [ "$got" = "hello world" ]
}

@test "_read_sanitized: whitespace-only input -> empty" {
  TB_TTY=/dev/stdin
  local got="unset"
  _read_sanitized "" got <<< "   "
  [ -z "$got" ]
}

@test "guard: new-dir choice with whitespace-only path aborts (#384 bugbot)" {
  seed_flat_mysql
  TB_LEFTOVER_ACTION=newdir TB_TTY=/dev/stdin run guard_leftover_data <<< "   "
  [ "$status" -eq 1 ]
  [[ "$output" == *"No new directory given"* ]]
  [ -e "$HOST_DATA_DIR/mysql/ibdata1" ]   # untouched
}
