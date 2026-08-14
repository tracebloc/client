#!/usr/bin/env bats
# hostPath PV dir prep — EXECUTES the shell that install-k8s.ps1 sends into the node.
#
# Why a bats mirror when install-k8s.Tests.ps1 already covers this: the Pester tests can only
# assert on the command STRING. They cannot run it, so they cannot catch the class of bug this
# code already had once — `stat -c` is a GNU/coreutils flag that BSD stat rejects, silently,
# leaving an empty mode string so a correctly-chmodded directory reports FAIL and the installer
# warns on a healthy install. Only running the thing finds that. These tests extract the real
# command out of the installer and execute it against temp dirs, so the OK/FAIL decision is
# exercised on whatever /bin/sh the runner has (and under dash, where POSIX is strict).
#
# Same review-ergonomics motive as gpu-embed-drift.bats: verifiable with no pwsh installed.

load test_helper

setup() {
  PS1_FILE="${SCRIPTS_DIR}/install-k8s.ps1"
  CHART_FILE="${SCRIPTS_DIR}/../client/templates/jobs-manager-deployment.yaml"
  TMP_BASE="$(mktemp -d)"
}

teardown() {
  [ -n "${TMP_BASE:-}" ] && rm -rf "$TMP_BASE"
}

# Pull the prep command out of the PowerShell here-string and make it runnable:
#  - strip the backticks PowerShell uses to escape shell $ (`$d -> $d)
#  - swap the interpolated $dirs for the two dirs under $1
# Note the installer parameterises the DATA base (it becomes /tracebloc-data when
# HOST_DATASET_DIR is set) while logs stay on /tracebloc; both land in $dirs, so
# substituting $dirs covers either layout.
_prep_cmd() {
  local base="$1" line
  line="$(grep -E '^for e in \$dirs; do d=' "$PS1_FILE" | tr -d '`')"
  [ -n "$line" ] || { echo "could not find the prep command in $PS1_FILE" >&2; return 1; }
  # $dirs carries path:mode pairs now (#667's per-dir split), so supply both.
  printf '%s\n' "${line/\$dirs/$base/data:2777 $base/logs:3777}"
}

@test "the extracted prep command is valid POSIX sh" {
  _prep_cmd "$TMP_BASE" > "$TMP_BASE/prep.sh" || return 1
  sh -n "$TMP_BASE/prep.sh" || return 1
  # dash is the strict POSIX check; skip rather than fail where it isn't installed.
  if command -v dash >/dev/null 2>&1; then
    dash -n "$TMP_BASE/prep.sh" || return 1
  fi
}

@test "the script runs the same way the installer delivers it: piped into sh on stdin" {
  # install-k8s.ps1 runs `docker exec -i <node> sh` and writes this script to STDIN, NOT as an
  # `sh -c <script>` argument: Invoke-BoundedProcess joins args into one command line and quotes
  # whitespace-containing args without escaping inner quotes, so an argv-borne script would be
  # truncated at its first embedded " on Windows and silently prepare nothing (#654 Bugbot).
  # Exercise the delivery the installer actually uses.
  run sh -c 'printf "%s\n" "$1" | sh' _ "$(_prep_cmd "$TMP_BASE")"
  [ "$status" -eq 0 ] || return 1
  [ -d "$TMP_BASE/data" ] || return 1
  [[ "$output" == *"OK $TMP_BASE/data"* ]] || return 1
  [[ "$output" != *FAIL* ]] || return 1
}

@test "fresh dirs are created and reported OK" {
  # The whole point: pre-create them so kubelet's DirectoryOrCreate never gets to make
  # them root:root 0755 (it also ignores fsGroup on hostPath — kubernetes#138411).
  run sh -c "$(_prep_cmd "$TMP_BASE")"
  [ "$status" -eq 0 ] || return 1
  [ -d "$TMP_BASE/data" ] || return 1
  [ -d "$TMP_BASE/logs" ] || return 1
  [[ "$output" == *"OK $TMP_BASE/data"* ]] || return 1
  [[ "$output" == *"OK $TMP_BASE/logs"* ]] || return 1
  [[ "$output" != *FAIL* ]] || return 1
}

@test "an already-writable dir stays OK and the run is idempotent" {
  # Installers get re-run; a second pass must not flip a good dir to FAIL.
  run sh -c "$(_prep_cmd "$TMP_BASE")"
  [ "$status" -eq 0 ] || return 1
  run sh -c "$(_prep_cmd "$TMP_BASE")"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *FAIL* ]] || return 1
}

@test "a non-writable dir is reported FAIL, not silently accepted" {
  # Simulates what kubelet leaves behind (mode 0755, not owned by uid 1000) with the
  # repair steps disabled — the state the installer must WARN about instead of claiming
  # success. Non-root can't chown to 1000, so this also covers a chown that fails.
  mkdir -p "$TMP_BASE/data" "$TMP_BASE/logs"
  chmod 755 "$TMP_BASE/data" "$TMP_BASE/logs"
  local cmd
  cmd="$(_prep_cmd "$TMP_BASE")"
  cmd="${cmd//mkdir -p/: }"
  cmd="${cmd//chown 1000:1000/: }"
  # \$want must stay LITERAL: unescaped, bash expands it to the empty string here and the
  # substitution silently matches nothing, leaving the chmod in place so the "non-writable"
  # setup is quietly writable and the test proves nothing.
  cmd="${cmd//chmod \"\$want\"/: }"
  run sh -c "$cmd"
  [[ "$output" == *"FAIL $TMP_BASE/data"* ]] || return 1
  [[ "$output" == *"FAIL $TMP_BASE/logs"* ]] || return 1
  [[ "$output" != *OK* ]] || return 1
}

# ── three-way mode parity: bash installer vs Windows installer vs chart (#673) ──
#
# The same intent is written out in three places, and it has already drifted once: #654
# gave the Windows prep a per-dir 2777/3777 split, #667 gave the chart the same one, and
# bash kept a flat recursive `chmod -R 777` through both PRs. Nothing was user-visibly
# broken by that (777 is other-writable and un-sticky, so `data delete` still worked), which
# is exactly why it survived — a divergence with no symptom needs a test, not a reviewer.
#
# Each extractor reads its OWN source of truth and reduces it to `<dir>:<mode>` pairs, so
# the comparison is on the shared meaning (which dir, what mode) rather than on paths, which
# legitimately differ: host paths on the bash side, in-node paths in the Windows prep, mount
# points in the chart. mysql is in none of them, by the same decision in all three (#654).

# bash: $HOST_DATA_DIR/<release>/{data,logs} -> data:2777 logs:3777
_bash_pairs() {
  (
    load_lib cluster.sh
    HOST_DATA_DIR="/tracebloc"
    unset HOST_DATASET_DIR
    _release_dirs_spec r | while IFS= read -r e; do
      p="${e%:*}"; printf '%s:%s\n' "${p##*/}" "${e##*:}"
    done
  ) | sort
}

# PowerShell: Get-ReleaseDirsSpec's Path/Mode rows, with the $TB_*_DIR_MODE constants
# resolved from their assignments. Parsed rather than executed so this stays runnable with
# no pwsh installed (same motive as the rest of this file).
_ps1_const() {
  grep -oE "^\\\$$1[[:space:]]*=[[:space:]]*\"[0-7]{3,4}\"" "$PS1_FILE" \
    | grep -oE '[0-7]{3,4}' | head -1
}
_ps1_pairs() {
  grep -oE 'Path = "[^"]+"; Mode = \$TB_[A-Z_]+' "$PS1_FILE" | while IFS= read -r line; do
    p="${line%%\"; Mode*}"; p="${p#Path = \"}"
    printf '%s:%s\n' "${p##*/}" "$(_ps1_const "${line##*Mode = \$}")"
  done | sort
}

# Chart: init-writable-data's `for e in /data/shared:2777 /data/logs:3777` loop. The mount
# point for the dataset dir is /data/shared, which is the same dir the other two call "data".
_chart_pairs() {
  grep -oE '/data/(shared|logs):[0-7]{3,4}' "$CHART_FILE" \
    | sed 's|^/data/shared:|data:|; s|^/data/logs:|logs:|' | sort -u
}

@test "bash _ensure_release_dirs and the Windows prep agree on every path:mode pair" {
  local bash_pairs ps1_pairs
  bash_pairs="$(_bash_pairs)"
  ps1_pairs="$(_ps1_pairs)"
  # Guard the extractors themselves: an empty match would make any comparison below pass.
  [ "$bash_pairs" = "$(printf 'data:2777\nlogs:3777')" ] || return 1
  [ "$ps1_pairs" = "$bash_pairs" ] || return 1
}

@test "the chart's init-writable-data agrees with both installers" {
  # #667's stated goal — installer and chart diffable by eye rather than drifting.
  local chart_pairs
  chart_pairs="$(_chart_pairs)"
  [ "$chart_pairs" = "$(printf 'data:2777\nlogs:3777')" ] || return 1
  [ "$chart_pairs" = "$(_bash_pairs)" ] || return 1
  [ "$chart_pairs" = "$(_ps1_pairs)" ] || return 1
}

@test "bash prepares the shared dirs WITHOUT -R" {
  # Recursing stamps setgid/sticky onto every data FILE and walks the whole dataset tree;
  # the Windows side argues the same in its own comment. The dir's own mode is what governs
  # creation and unlink inside it. mysql keeps its recursive chmod and is not asserted here.
  local body recursive
  body="$(awk '/^_ensure_release_dirs\(\)/,/^}/' "${SCRIPTS_DIR}/lib/cluster.sh")"
  [ -n "$body" ] || return 1
  [[ "$body" == *'chmod "$mode" "$dir"'* ]] || return 1
  # Exactly one recursive chmod is left in the function, and it is mysql's.
  recursive="$(printf '%s\n' "$body" | grep -c 'chmod -R')"
  [ "$recursive" -eq 1 ] || return 1
  printf '%s\n' "$body" | grep 'chmod -R' | grep -q 'mysql' || return 1
}

@test "the mode is read with POSIX ls -ldn, never GNU-only stat -c" {
  # Regression guard on the real bug: stat -c fails silently on BSD, so a 3777 dir got
  # reported FAIL. Same family as the sha256sum --check trap (#429).
  local line
  line="$(grep -E '^for e in \$dirs; do d=' "$PS1_FILE" | tr -d '`')"
  [[ "$line" == *"ls -ldn"* ]] || return 1
  [[ "$line" != *"stat -c"* ]] || return 1
}
