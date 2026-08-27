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

# The two advisories, by name — DERIVED, not restated: whatever the healthy
# hand-off calls before _assess_handoff is what every early-exit owes. Sourcing
# assess.sh means a rename that misses a call site is caught by the behavioral
# tests below; this list only names what the enumeration greps for.
ADVISORIES=(_check_existing_cluster_k8s_version _check_healthy_cluster_gpu_consistent)

# _funcs_with_exit FILE — function names whose body contains an `exit` statement,
# i.e. the installer-TERMINATING functions in FILE. These libs are sourced (no
# top-level code), so an `exit` is always inside the last-opened function.
# Recognises BOTH `name() {` and `function name {` definition styles, so a new
# early-exit written the other way can't slip attribution to a prior function.
_funcs_with_exit() {
  awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/  { fn=$0; sub(/\(\).*/,"",fn) }
    /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/ { fn=$2; sub(/\(\).*/,"",fn) }
    /^[[:space:]]*exit([[:space:]]|$)/           { if (fn!="") print fn }
  ' "$1" | sort -u
}

# _funcs_calling FILE SYMBOL — function names whose body calls SYMBOL (ignoring
# comment-only lines). Used to prove each advisory is called from each early-exit
# decision function. Same dual definition-style recognition as _funcs_with_exit.
_funcs_calling() {
  awk -v sym="$2" '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/  { fn=$0; sub(/\(\).*/,"",fn) }
    /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/ { fn=$2; sub(/\(\).*/,"",fn) }
    $0 !~ /^[[:space:]]*#/ && index($0, sym)     { if (fn!="") print fn }
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

# Each early-exit DECISION function must call BOTH advisories. Derived per-symbol
# so dropping either one from either path is caught here (in addition to the
# behavioral tests) — the static half survives even if someone deletes a test.
@test "every early-exit decision calls BOTH advisories (source-level)" {
  local sym
  for sym in "${ADVISORIES[@]}"; do
    _funcs_calling "$ASSESS" "$sym" | grep -qx "assess_existing_install" || {
      echo "$sym is not called in assess_existing_install (healthy hand-off)"; return 1; }
    _funcs_calling "$INSTALL_CLI" "$sym" | grep -qx "upgrade_cli_only" || {
      echo "$sym is not called in upgrade_cli_only (cli-behind-latest path)"; return 1; }
  done
}

# ── The enumeration itself works: it DETECTS an unguarded early-exit ─────────
# Proves the guard would fire on the very shape it exists to catch, rather than
# passing vacuously — a fixture lib with a new exit-bearing function that skips
# the advisories, which _funcs_with_exit must surface.
@test "the enumeration catches a new unguarded early-exit (fixture)" {
  local fix="$BATS_TEST_TMPDIR/newpath.sh"
  cat > "$fix" <<'EOF'
existing_terminal() {
  _check_existing_cluster_k8s_version
  _check_healthy_cluster_gpu_consistent
  exit 0
}
sneaky_new_only() {          # a new early-exit that FORGOT the advisories
  info "doing just one thing"
  exit 0
}
EOF
  local got; got="$(_funcs_with_exit "$fix")"
  printf '%s\n' "$got" | grep -qx "sneaky_new_only" || {
    echo "enumeration missed a new exit-bearing function; saw: [$got]"; return 1; }
  # And the per-symbol check would flag it: sneaky_new_only calls neither advisory.
  _funcs_calling "$fix" "_check_healthy_cluster_gpu_consistent" | grep -qx "sneaky_new_only" && {
    echo "fixture wrongly reports the unguarded fn as calling the advisory"; return 1; }
  return 0
}
