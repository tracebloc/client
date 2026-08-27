#!/usr/bin/env bats
# Guard: every EARLY-EXIT path out of the assess stop-and-check reaches the
# cluster drift/GPU advisories (backend#2674).
#
# assess short-circuits an already-set-up machine BEFORE the normal flow reaches
# _handle_existing_cluster, where `_check_existing_cluster_k8s_version` (k3s
# drift, #547/#565) and `_check_healthy_cluster_gpu_consistent` (GPU, client#835/
# #852) run. So every path that terminates the installer early has to run BOTH
# advisories itself, or a healthy-but-drifted k3s / an unschedulable-GPU cluster
# gets no signal.
#
# We kept fixing this ONE INSTANCE AT A TIME — always the same shape, "a correct
# fix that lands above a guard added to close a previous early-exit gap": the k3s
# check, then the GPU check, then the `cli-behind-latest` -> upgrade_cli_only path
# (backend#2253), each patched only after the omission was spotted. This suite
# catches the CLASS: it drives each known early-exit terminal and asserts both
# advisories run, AND — the part that matters — it ENUMERATES the early-exit
# terminals from source and FAILS CLOSED when a new, uncovered one appears, so the
# next instance can't ship silently.
#
# (macOS bash-3.2 blindspot, per assess.bats: a bare `[[ … ]]` as a test's last
# statement can pass vacuously. Content assertions go through grep + an explicit
# `return 1`; Linux CI is the authority.)
bats_require_minimum_version 1.7.0
load test_helper

setup() {
  load_lib cluster.sh                          # common.sh + cluster.sh
  # shellcheck source=/dev/null
  source "${LIB_DIR}/install-client-helm.sh"   # detect_installed_client (assess dep)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"           # sourced before assess.sh in install-k8s.sh
  # shellcheck source=/dev/null
  source "${LIB_DIR}/assess.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/install-cli.sh"           # upgrade_cli_only
  ASSESS="${LIB_DIR}/assess.sh"
  INSTALL_CLI="${LIB_DIR}/install-cli.sh"
  unset TB_FORCE_REINSTALL TRACEBLOC_FORCE_REINSTALL INSTALL_STATE INSTALL_STATE_REASON \
        TB_UPGRADE_CLI TB_CLI_LATEST
}

# _advisories_in FUNC FILE — the drift/GPU advisory functions FUNC guards, DERIVED
# from `declare -F <name>` guards on names matching the advisory convention
# (_check_*). NOT a hardcoded list: a restated pair would let a NEW advisory be
# added to one early-exit and silently skipped on another — the same class this
# suite stops, one axis over (Bugbot). Keys on `declare -F <name>` so it catches
# BOTH guard idioms — the one-liner `declare -F X … && X` AND the block
# `if declare -F X …; then X; fi` (both spell the guard the same way); the _check_
# convention is what separates an advisory from other guarded calls
# (install_tracebloc_cli, which the hand-off legitimately does not run). Comment
# lines are skipped so a commented-out guard can't pad the set (Bugbot).
_advisories_in() {
  awk -v want="$1" '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/  { fn=$0; sub(/\(\).*/,"",fn) }
    /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/ { fn=$2; sub(/\(\).*/,"",fn) }
    fn==want {
      l=$0
      if (l ~ /^[[:space:]]*#/) next     # full-line comment
      sub(/[[:space:]]#.*/,"",l)         # strip trailing inline comment
      if (l ~ /declare -F _check_[A-Za-z0-9_]/) {
        sub(/.*declare -F /,"",l); sub(/[^A-Za-z0-9_].*/,"",l); print l
      }
    }
  ' "$2" | sort -u
}

# _funcs_with_exit FILE — function names whose body contains an `exit` COMMAND,
# i.e. the installer-TERMINATING functions in FILE. These libs are sourced (no
# top-level code), so an `exit` is always inside the last-opened function.
# Recognises both `name() {` and `function name {` definitions, and `exit` in ANY
# position — leading, `… && exit`, `…; exit`, `then exit` — matched as a word so
# `exitcode`/`_exit` don't false-positive; full-line comments are skipped and
# trailing inline comments stripped, so prose mentioning exit can't (Bugbot).
_funcs_with_exit() {
  awk '
    BEGIN { sq = sprintf("%c", 39) }        # a literal single quote, no escaping games
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/  { fn=$0; sub(/\(\).*/,"",fn) }
    /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/ { fn=$2; sub(/\(\).*/,"",fn) }
    {
      l=$0
      if (l ~ /^[[:space:]]*#/) next        # full-line comment
      gsub(sq "[^" sq "]*" sq, "", l)       # strip single-quoted spans (e.g. an embedded awk program: awk '"'"'… exit }'"'"')
      gsub(/"[^"]*"/, "", l)                # strip double-quoted spans
      sub(/[[:space:]]#.*/,"",l)            # then strip a real trailing comment
      if (fn!="" && l ~ /(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)/) print fn
    }
  ' "$1" | sort -u
}

# ── Behavioral: each known early-exit terminal runs BOTH advisories ──────────
# The healthy hand-off exits before _handle_existing_cluster, so assess_existing_
# install must run both advisories itself, before handing off.
@test "healthy hand-off runs BOTH drift/GPU advisories before the hand-off" {
  _assess_classify() { INSTALL_STATE=healthy; INSTALL_STATE_REASON="ns:x"; }
  _check_existing_cluster_k8s_version() { echo "K8S_DRIFT_RAN"; }
  _check_healthy_cluster_gpu_consistent() { echo "GPU_CHECK_RAN"; }
  _assess_handoff() { echo "HANDOFF_RAN"; }        # stub: don't exit under `run`
  run assess_existing_install
  [ "$status" -eq 0 ] || return 1
  # Both advisories, AND before the hand-off (a drift warning after the home
  # screen has taken the terminal is a warning nobody sees).
  printf '%s\n' "$output" | grep -q "K8S_DRIFT_RAN" || { echo "k3s drift advisory did not run"; return 1; }
  printf '%s\n' "$output" | grep -q "GPU_CHECK_RAN" || { echo "GPU advisory did not run"; return 1; }
  printf '%s\n' "$output" | grep -q "HANDOFF_RAN"  || { echo "hand-off did not run"; return 1; }
  # order: both advisories precede the hand-off line
  local order; order="$(printf '%s\n' "$output" | grep -nE 'K8S_DRIFT_RAN|GPU_CHECK_RAN|HANDOFF_RAN')"
  [ "$(printf '%s\n' "$order" | tail -1 | grep -c HANDOFF_RAN)" -eq 1 ] || { echo "hand-off not last:\n$order"; return 1; }
}

# The cli-behind-latest path (backend#2253) exits before _handle_existing_cluster
# too, so upgrade_cli_only must run both advisories.
@test "upgrade_cli_only runs BOTH drift/GPU advisories" {
  info() { :; }
  install_tracebloc_cli() { :; }
  _cli_version_short() { echo ""; }               # can't prove failure -> clean exit 0
  _check_existing_cluster_k8s_version() { echo "K8S_DRIFT_RAN"; }
  _check_healthy_cluster_gpu_consistent() { echo "GPU_CHECK_RAN"; }
  run upgrade_cli_only
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q "K8S_DRIFT_RAN" || { echo "k3s drift advisory did not run"; return 1; }
  printf '%s\n' "$output" | grep -q "GPU_CHECK_RAN" || { echo "GPU advisory did not run"; return 1; }
}

# ── Static enumeration: the CLASS guard (fails closed on a new early-exit) ────
# The complete set of installer-terminating functions across the two files is
# pinned. A NEW one (a fresh `foo_only` that exits, or anything that calls
# `_assess_handoff` a second time) trips this and forces whoever adds it to run
# both advisories on the new path AND record it here — instead of shipping the
# next instance of the bug and fixing it after the fact.
@test "assess.sh's ONLY exit-bearing function is _assess_handoff" {
  local got; got="$(_funcs_with_exit "$ASSESS")"
  [ "$got" = "_assess_handoff" ] || {
    echo "New early-exit terminal(s) in assess.sh: [$got]"
    echo "Every early-exit must run both drift/GPU advisories (backend#2674) — cover the new path, then update this pin."
    return 1
  }
}

@test "install-cli.sh's ONLY exit-bearing function is upgrade_cli_only" {
  local got; got="$(_funcs_with_exit "$INSTALL_CLI")"
  [ "$got" = "upgrade_cli_only" ] || {
    echo "New early-exit terminal(s) in install-cli.sh: [$got]"
    echo "Every early-exit must run both drift/GPU advisories (backend#2674) — cover the new path, then update this pin."
    return 1
  }
}

@test "_assess_handoff has exactly ONE call site (the healthy branch)" {
  # A second invocation is a new early-exit routing through the hand-off; it must
  # run the advisories before handing off and be added to the behavioral coverage.
  local n; n="$(grep -cE '^[[:space:]]*_assess_handoff([[:space:]]|$)' "$ASSESS")"
  [ "$n" -eq 1 ] || {
    echo "Expected 1 _assess_handoff call site in assess.sh, found $n."
    echo "A new hand-off path must run both drift/GPU advisories first (backend#2674)."
    return 1
  }
}

# The SAME advisory set must run on every early-exit — DERIVED from the healthy
# hand-off (the reference path) and asserted equal on upgrade_cli_only. This is
# the advisory-axis class-catcher (Bugbot): dropping an advisory from one path,
# OR adding a new advisory to one path but not the other, makes the sets diverge
# and fails here — no hardcoded pair to keep in sync.
@test "every early-exit runs the SAME derived advisory set (parity)" {
  local ref other
  ref="$(_advisories_in assess_existing_install "$ASSESS")"
  other="$(_advisories_in upgrade_cli_only "$INSTALL_CLI")"
  # Fail closed: the reference path must actually name advisories, or the
  # derivation (or the hand-off) changed shape and this guard would pass vacuously.
  [ -n "$ref" ] || { echo "derived NO advisories from the healthy hand-off — derivation or hand-off changed shape"; return 1; }
  [ "$ref" = "$other" ] || {
    echo "advisory sets diverge — a drift/GPU check runs on one early-exit but not the other:"
    echo "  healthy hand-off : $(echo $ref)"
    echo "  upgrade_cli_only : $(echo $other)"
    echo "Add the missing advisory to the other path too (backend#2674, advisory axis)."
    return 1
  }
}

# ── The enumeration itself works: it DETECTS unguarded early-exits ───────────
# Proves the guard fires on the very shapes it exists to catch, rather than
# passing vacuously. Plants new exit-bearing functions in EVERY exit spelling
# (leading, `&& exit`, `; exit`, `then exit`) — the compound forms a first-token-
# only scan would miss (Bugbot) — plus a `#`-commented exit that must NOT count.
@test "the enumeration catches new unguarded early-exits, in every exit spelling (fixture)" {
  local fix="$BATS_TEST_TMPDIR/newpath.sh"
  cat > "$fix" <<'EOF'
existing_terminal() {
  exit 0
}
sneaky_and_only() {          # && exit
  probe && exit 0
}
sneaky_semi_only() {         # ; exit
  probe; exit 1
}
sneaky_then_only() {         # then exit
  if probe; then exit 0; fi
}
just_a_comment() {           # mentions exit 0 in prose only — must NOT count
  info "nothing terminal here"
}
awk_string_only() {          # `exit` only inside an embedded awk program — must NOT count
  probe | awk '$1 == n { print; exit }'
}
EOF
  local got; got="$(_funcs_with_exit "$fix")"
  local want
  for want in existing_terminal sneaky_and_only sneaky_semi_only sneaky_then_only; do
    printf '%s\n' "$got" | grep -qx "$want" || {
      echo "enumeration missed exit-bearing fn '$want'; saw: [$got]"; return 1; }
  done
  printf '%s\n' "$got" | grep -qx "just_a_comment" && {
    echo "a prose-only 'exit' mention was wrongly counted as a terminal"; return 1; }
  printf '%s\n' "$got" | grep -qx "awk_string_only" && {
    echo "an 'exit' inside a quoted awk program was wrongly counted as a terminal"; return 1; }

  # And the advisory derivation ignores a commented-out guard (no false parity):
  # a function whose only _check_ guard is commented out derives an EMPTY set.
  cat > "$fix" <<'EOF'
commented_guard_only() {
  # declare -F _check_healthy_cluster_gpu_consistent >/dev/null 2>&1 && _check_healthy_cluster_gpu_consistent
  exit 0
}
EOF
  [ -z "$(_advisories_in commented_guard_only "$fix")" ] || {
    echo "a commented-out advisory guard was counted"; return 1; }
  return 0
}
