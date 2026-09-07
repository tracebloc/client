#!/usr/bin/env bats
# =============================================================================
#  bounded-reads-propagate.bats — every BOUNDED daemon read must reach its caller
#  as THREE distinguishable outcomes: yes / no / couldn't tell.
#
#  WHY THIS EXISTS, and why it is shaped as a class guard rather than a per-site
#  one. client#974 bounded the installer's engine reads. Bounding a call ADDS AN
#  OUTCOME — before it a probe answered yes/no, after it there is also "the
#  deadline fired" — and that third outcome was then collapsed into one of the
#  first two at four separate sites, in three separate review rounds:
#
#    1. `_cluster_exists` returned 1 (ABSENT) on a timeout, so create_cluster ran
#       guard_leftover_data — which PROMPTS, with delete among the options — and
#       _create_new_cluster, against a cluster that was probably still running;
#       and assess reported `fresh`, offering a first-time install over a live
#       machine (Bugbot High + LukasWodka BLOCKING, client#984).
#    2. After the tri-state landed, a SUCCESSFUL JSON listing that proved the
#       cluster absent still fell through to the table probe, whose timeout
#       returned UNKNOWN — so a first-time install with jq present tried to START
#       a cluster the listing had just proved absent (Bugbot High, round 2).
#    3. `docker inspect … | grep -iE PROXY` in the --diagnose bundle: a fired
#       deadline yields empty grep output, indistinguishable from "this node has
#       no proxy env" — on a machine being diagnosed FOR a proxy problem.
#    4. `docker info … | grep -iE 'Server Version|…'`: same shape, same file.
#
#  Fixing sites was not converging, so this pins the SHAPE:
#
#    A. THE CENSUS. Every bounded daemon read in the installer libs is counted,
#       derived from check-style.sh's OWN invocation regexes rather than a second
#       hand-written copy, and the function containing each one must appear in the
#       coverage table below. A read added to a function nobody drives three ways
#       reddens here. (This is the "extend the census from 'is it bounded' to
#       'does it propagate three states'" half.)
#    B. THE OUTCOMES. Each function in the table is driven three ways and must
#       produce three DISTINCT observable results. Distinctness is the assertion:
#       "does a bound exist?" was green on every one of the four defects above.
#    C. THE SAFE SIDE. Where a caller must reduce three states to a decision, the
#       decision on "couldn't tell" must be the one that cannot destroy anything —
#       don't create, don't claim fresh, don't report "no proxy" — and it must be
#       VISIBLE to the caller. A `log` line the caller cannot inspect is not a
#       return value; that was Lukas's point about `_cluster_exists`.
#
#  No cluster, no Docker, no network: mocks only.
# =============================================================================
load test_helper

setup() {
  load_lib cluster.sh
  # shellcheck source=/dev/null
  source "${LIB_DIR}/install-client-helm.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/assess.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/diagnose.sh"
  MOCK_CALLS="$(mktemp)"
  CLUSTER_NAME=tracebloc
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  LOG_FILE=/dev/null
  CS="${BATS_TEST_DIRNAME}/../check-style.sh"

  # ── THE COVERAGE TABLE ─────────────────────────────────────────────────────
  # Functions whose three outcomes an @test in THIS FILE actually drives. Nothing
  # else belongs here: a name listed without a test behind it is precisely the
  # "reports coverage it structurally cannot provide" defect this file exists to
  # catch, so the list is short on purpose and grows only with a test.
  COVERED_FUNCTIONS="
_cluster_presence
_handle_existing_cluster
create_cluster
_assess_classify
_assess_cluster_servers_running
run_diagnose
_bounded_capture
_bounded_capture_read
"

  # ── the explicitly-named, RATCHETED remainder ──────────────────────────────
  # Bounded daemon reads that predate client#984 and are not driven three ways
  # here. Named, as client#974's own issue text asked ("with any deliberate
  # exemption named explicitly"), rather than silently skipped — and ratcheted by
  # the tests below, which fail if the list GROWS or names a function that no
  # longer exists. A NEW bounded read therefore has to be driven three ways and
  # added to COVERED_FUNCTIONS; it cannot be parked here.
  #
  # Why each is out of scope rather than wrong: every one is a best-effort read
  # whose timeout branch is already a `|| return 0` / `|| true` no-op on a path
  # that reconciles anyway (the _check_existing_cluster_* drift probes,
  # _generate_node_cdi_specs, ensure_cluster_autostart), a yes/no liveness probe
  # that is already tri-state or has no third state to lose (_docker_answers,
  # _k3d_cluster_running, _assess_runtime_down, _docker_default_runtime_is_nvidia),
  # or a preflight/install step that reports its own failure to the operator
  # (install_docker_engine, install_rootless_docker, _pf_*, _tier0_gpu_flags,
  # render_host_audit). None converts "couldn't tell" into a claim about the
  # machine, which is the defect class this file guards. Auditing them one by one
  # is a separate ticket, not this diff.
  PRE_EXISTING_UNCOVERED="
_assess_runtime_down
_check_existing_cluster_bind
_check_existing_cluster_ca
_check_existing_cluster_dataset_mount
_check_existing_cluster_gpu
_check_existing_cluster_k8s_version
_check_existing_cluster_kubelet_config
_check_existing_cluster_proxy
_check_existing_cluster_storage_mode
_check_healthy_cluster_gpu_consistent
_docker_answers
_docker_default_runtime_is_nvidia
_generate_node_cdi_specs
_k3d_cluster_running
_pf_docker_root
_pf_runtime_mem_kb
_pf_runtime_ncpu
_tier0_gpu_flags
_verify_nodes_see_host_data
ensure_cluster_autostart
install_docker_engine
install_rootless_docker
render_host_audit
"
  PRE_EXISTING_CEILING=23
}


# ── the derivation: check-style's OWN regexes, not a second copy ─────────────
_probe_re() {   # $1 = docker_probe | k3d_list_probe
  local line
  line="$(grep -m1 "^$1=" "$CS")" || return 1
  line="${line#"$1"=\'}"; printf '%s' "${line%\'}"
}

# Every bounded daemon-read line in scripts/lib, as "file:line:text".
_bounded_read_sites() {
  local dre kre
  dre="$(_probe_re docker_probe)" || return 1
  kre="$(_probe_re k3d_list_probe)" || return 1
  [ -n "$dre" ] && [ -n "$kre" ] || return 1
  grep -rnE --include='*.sh' "$dre|$kre" "${BATS_TEST_DIRNAME}/../lib/" 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -vE '# *style-guard: *allow' \
    | grep -E '(_bounded|_bounded_capture|_bounded_root|timeout|gtimeout)'
}

# The function a given file:line sits inside — the nearest preceding `name() {`.
_enclosing_function() {   # $1 = file, $2 = line
  awk -v want="$2" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { name = $0; sub(/\(\).*/, "", name) }
    NR == want { print name; exit }
  ' "$1"
}

@test "A. census: the derivation finds the bounded daemon reads (it has not gone vacuous)" {
  local n
  n="$(_bounded_read_sites | grep -c . || true)"
  [ "$n" -ge 20 ] || {
    echo "derived only $n bounded daemon read(s) from scripts/lib — the extraction (or check-style's regexes it reads) has gone vacuous, and every assertion below would then pass while checking nothing"
    _bounded_read_sites
    return 1
  }
}

@test "A. census: EVERY bounded daemon read sits in a function this file covers" {
  # The half that stops a new read from slipping in unhandled. If this reddens,
  # either drive the new function's three outcomes and add it to COVERED_FUNCTIONS,
  # or say on the PR why that read has no third state to propagate.
  local site file line fn missing=""
  while read -r site; do
    [ -n "$site" ] || continue
    file="${site%%:*}"; site="${site#*:}"; line="${site%%:*}"
    fn="$(_enclosing_function "$file" "$line")"
    [ -n "$fn" ] || fn="<top-level>"
    printf '%s\n' "$COVERED_FUNCTIONS" | grep -qx -- "$fn" && continue
    printf '%s\n' "$PRE_EXISTING_UNCOVERED" | grep -qx -- "$fn" && continue
    missing="$missing
  $fn  ($(basename "$file"):$line)"
  done <<< "$(_bounded_read_sites)"
  [ -z "$missing" ] || {
    echo "bounded daemon read(s) in function(s) with no three-outcome coverage:$missing"
    echo
    echo "Drive the function's yes/no/couldn't-tell outcomes and add it to"
    echo "COVERED_FUNCTIONS. Do NOT add it to PRE_EXISTING_UNCOVERED — that list is"
    echo "ratcheted and is for reads that predate client#984."
    return 1
  }
}

@test "A. census: the pre-existing exemption list only RATCHETS DOWN" {
  # An exemption list anyone may append to is not a guard, it is a formality. This
  # is the same ratchet the SDK's per-file line budgets use: the number may fall as
  # these reads get audited, never rise.
  local n
  n="$(printf '%s\n' "$PRE_EXISTING_UNCOVERED" | grep -c . || true)"
  [ "$n" -le "$PRE_EXISTING_CEILING" ] || {
    echo "PRE_EXISTING_UNCOVERED has grown to $n (ceiling $PRE_EXISTING_CEILING) — a new bounded read belongs in COVERED_FUNCTIONS with its three outcomes driven, not here"
    return 1
  }
}

@test "A. census: every exempted function still EXISTS (the list cannot rot)" {
  # A stale name is an exemption for nothing, and it hides the read that replaced it.
  local fn missing=""
  while read -r fn; do
    [ -n "$fn" ] || continue
    grep -rqE "^${fn}\(\)[[:space:]]*\{" "${BATS_TEST_DIRNAME}/../lib/"*.sh \
      || missing="$missing $fn"
  done <<< "$PRE_EXISTING_UNCOVERED"
  [ -z "$missing" ] || {
    echo "PRE_EXISTING_UNCOVERED names function(s) that no longer exist:$missing"
    return 1
  }
}

# ── B. the outcomes, per verdict-bearing function ───────────────────────────

@test "B. _cluster_presence: yes / no / couldn't-tell are three DISTINCT statuses" {
  # `|| x=$?`, never `( … ); x=$?` — bats runs a test body under errexit, so a
  # subshell that returns non-zero aborts the test before the capture. Same trap
  # the fix itself hit in cluster.sh.
  local yes=0 no=0 unknown=0
  ( _bounded() { shift; "$@"; }; k3d() { printf 'tracebloc 1/1 0/0\n'; }
    command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
    _cluster_presence ) || yes=$?
  ( _bounded() { shift; "$@"; }; k3d() { printf 'other 1/1 0/0\n'; }
    command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
    _cluster_presence ) || no=$?
  ( _bounded() { return 124; }; k3d() { printf 'tracebloc 1/1 0/0\n'; }
    command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
    _cluster_presence ) || unknown=$?
  [ "$yes" -eq 0 ] || { echo "present=$yes"; return 1; }
  [ "$no" -eq 1 ] || { echo "absent=$no"; return 1; }
  [ "$unknown" -eq 2 ] || { echo "unknown=$unknown"; return 1; }
  [ "$yes" -ne "$no" ] && [ "$no" -ne "$unknown" ] && [ "$yes" -ne "$unknown" ] || return 1
}

@test "B. _cluster_presence: an AUTHORITATIVE answer beats a later probe's timeout" {
  # Bugbot High, round 2. The JSON read SUCCEEDS and proves the cluster absent; the
  # table read then times out. ABSENT must win — a definite answer from a read that
  # completed always beats "couldn't tell" from one that did not. Collapsing this to
  # UNKNOWN made a first-time install with jq present try to START a cluster the
  # listing had just proved absent, instead of creating one.
  local rc=0
  _bounded() {
    shift
    case "$*" in
      *"-o json"*) printf '[]\n' ;;      # a real, parseable, EMPTY listing
      *)           return 124 ;;         # every later read times out
    esac
  }
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
  _cluster_presence || rc=$?
  [ "$rc" -eq 1 ] || { echo "expected ABSENT(1) from the authoritative JSON read, got $rc"; return 1; }
}

@test "B. _cluster_presence: an UNPARSEABLE JSON payload is inconclusive, not absent" {
  # The other side of the same coin, and the reason the table probes exist at all:
  # `jq -e` cannot tell "no match" from "not JSON" — both are non-zero — so the
  # payload SHAPE is checked first, and a non-array falls through instead of being
  # reported as an empty cluster list.
  local rc=0
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
  _bounded() {
    shift
    case "$*" in
      *"-o json"*) printf 'FATA[0000] not json at all\n' ;;
      *)           return 124 ;;
    esac
  }
  _cluster_presence || rc=$?
  [ "$rc" -eq 2 ] || { echo "expected UNKNOWN(2) after an unparseable payload + a timed-out fallback, got $rc"; return 1; }
}

@test "B. create_cluster: the three outcomes reach three DIFFERENT branches" {
  local present absent unknown
  _mocks() {
    _rootless_active() { return 1; }
    _ensure_tracebloc_dirs() { :; }
    _pf_recheck_runtime_mem() { return 0; }
    ensure_cluster_autostart() { :; }
    _merge_kubeconfig() { :; }
    _export_host_no_proxy() { :; }
    # EVERYTHING create_cluster calls AFTER the branch under test, too. Left
    # unmocked, `_wait_for_api` ran for real against no cluster: 180s of `kubectl
    # cluster-info` per drive, then a non-zero return that errexit turned into an
    # aborted test — so this test spent nine minutes proving nothing and then
    # reported the abort at the FIRST drive, before a single branch was compared.
    # A test that cannot reach its own assertions is not a guard.
    _wait_for_api() { :; }
    _verify_nodes_see_host_data() { :; }
    _generate_node_cdi_specs() { :; }
    TB_STORAGE_MODE=node-local
  }
  present="$( _mocks; guard_leftover_data() { echo GUARD; }; _handle_existing_cluster() { echo REUSE; }
              _create_new_cluster() { echo CREATE; }; _cluster_presence() { return 0; }
              create_cluster 2>/dev/null )"
  absent="$(  _mocks; guard_leftover_data() { echo GUARD; }; _handle_existing_cluster() { echo REUSE; }
              _create_new_cluster() { echo CREATE; }; _cluster_presence() { return 1; }
              create_cluster 2>/dev/null )"
  unknown="$( _mocks; guard_leftover_data() { echo GUARD; }; _handle_existing_cluster() { echo REUSE; }
              _create_new_cluster() { echo CREATE; }; _cluster_presence() { return 2; }
              create_cluster 2>/dev/null )"
  printf '%s\n' "$present" | grep -qx REUSE  || { echo "present -> $present"; return 1; }
  printf '%s\n' "$present" | grep -qx GUARD  && { echo "present guarded data"; return 1; }
  printf '%s\n' "$absent"  | grep -qx GUARD  || { echo "absent -> $absent"; return 1; }
  printf '%s\n' "$absent"  | grep -qx CREATE || { echo "absent -> $absent"; return 1; }
  printf '%s\n' "$unknown" | grep -qx REUSE  || { echo "unknown -> $unknown"; return 1; }
  printf '%s\n' "$unknown" | grep -qx GUARD  && { echo "unknown prompted about data"; return 1; }
  printf '%s\n' "$unknown" | grep -qx CREATE && { echo "unknown created a cluster"; return 1; }
  # C. the safe side is also VISIBLE — a caller-inspectable line, not just a log.
  [ "$absent" != "$unknown" ] || return 1
}

@test "B. _handle_existing_cluster: an unreadable status says so, and still takes the safe action" {
  # The action is the same for "stopped" and "couldn't tell" — `k3d cluster start`
  # is idempotent and bounded — so the outcome that must differ is the CLAIM. Saying
  # "exists but is stopped" off a listing that never completed is the same defect
  # this PR is about, and it points the operator at the wrong thing on a run where
  # the cluster may well be up.
  local running stopped unknown
  _drive() {   # $1 = read rc, $2 = servers text
    local rc="$1" txt="$2"
    ( command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
      _bounded() { [ "$rc" -eq 0 ] || return "$rc"; printf '%s\n' "$txt"; }
      k3d() { return 0; }
      success() { echo "SUCCESS: $*"; }
      log() { echo "LOG: $*"; }
      error() { echo "ERROR: $*"; return 1; }
      _check_existing_cluster_proxy() { :; };  _check_existing_cluster_ca() { :; }
      _check_existing_cluster_bind() { :; };   _check_existing_cluster_dataset_mount() { :; }
      _check_existing_cluster_kubelet_config() { :; }
      _check_existing_cluster_storage_mode() { :; }
      _check_existing_cluster_k8s_version() { :; }; _check_existing_cluster_gpu() { :; }
      _handle_existing_cluster 2>&1 )
  }
  running="$(_drive 0 'tracebloc 1/1 0/0')"
  stopped="$(_drive 0 'tracebloc 0/1 0/0')"
  unknown="$(_drive 124 'tracebloc 1/1 0/0')"
  printf '%s\n' "$running" | grep -q 'already running' || { echo "running -> $running"; return 1; }
  printf '%s\n' "$stopped" | grep -q 'exists but is stopped' || { echo "stopped -> $stopped"; return 1; }
  printf '%s\n' "$unknown" | grep -q "Couldn't read whether" || { echo "unknown -> $unknown"; return 1; }
  # THE ASSERTION THAT MATTERS: the unreadable case must not CLAIM it is stopped...
  printf '%s\n' "$unknown" | grep -q 'exists but is stopped' && { echo "claimed 'stopped' off an unreadable listing"; return 1; }
  # ...and must still take the safe, idempotent action.
  printf '%s\n' "$unknown" | grep -q 'Secure environment started' || { echo "unknown skipped the start: $unknown"; return 1; }
  [ "$running" != "$stopped" ] && [ "$stopped" != "$unknown" ] || return 1
}

@test "B. _assess_classify: the three outcomes reach three DIFFERENT verdicts" {
  local p_state a_state u_state
  _drive() {   # $1 = presence rc
    local want="$1"
    ( has() { return 0; }
      _assess_runtime_down() { return 1; }
      # `$want`, not `$1`: inside the stub `$1` is the STUB's own argument list.
      _cluster_presence() { return "$want"; }
      _assess_cluster_servers_running() { echo 1; }
      _assess_workload_ready() { return 0; }
      _assess_cli_present() { return 0; }
      _assess_cli_outdated() { return 1; }
      _assess_cli_behind_latest() { return 1; }
      _assess_release_pending() { return 1; }
      detect_installed_client() { INSTALLED_CLIENT_NS="tracebloc"; }
      _assess_classify >/dev/null 2>&1
      printf '%s/%s' "$INSTALL_STATE" "$INSTALL_STATE_REASON" )
  }
  p_state="$(_drive 0)"; a_state="$(_drive 1)"; u_state="$(_drive 2)"
  [ "$a_state" = "fresh/no-cluster" ] || { echo "absent -> $a_state"; return 1; }
  [ "$u_state" = "degraded/cluster-indeterminate" ] || { echo "unknown -> $u_state"; return 1; }
  case "$u_state" in fresh/*|healthy/*) echo "unknown -> $u_state"; return 1 ;; esac
  [ "$p_state" != "$a_state" ] && [ "$a_state" != "$u_state" ] || { echo "$p_state / $a_state / $u_state"; return 1; }
}

@test "B. _assess_cluster_servers_running: a timeout is 0, and 0 degrades (never 'healthy')" {
  local n
  n="$( _bounded() { return 124; }; k3d() { printf 'tracebloc 1/1 0/0\n'; }
        _assess_cluster_servers_running )"
  [ "$n" = "0" ] || { echo "timeout -> $n"; return 1; }
  n="$( _bounded() { shift; "$@"; }; k3d() { printf 'tracebloc 1/1 0/0\n'; }
        _assess_cluster_servers_running )"
  [ "$n" = "1" ] || { echo "running -> $n"; return 1; }
}

@test "B. _bounded_capture itself reports three outcomes distinguishably" {
  # The primitive the --diagnose reads now use, and the one whose bound survives a
  # stock Mac. If IT collapsed the states, everything above it would too.
  local out="$BATS_TEST_TMPDIR/cap" rc
  rc=0; _bounded_capture 5 "$out" printf 'hello\n' || rc=$?
  [ "$rc" -eq 0 ] || { echo "success -> $rc"; return 1; }
  grep -qx hello "$out" || { echo "output not captured"; return 1; }
  rc=0; _bounded_capture 5 "$out" false || rc=$?
  [ "$rc" -eq 1 ] || { echo "command failure -> $rc"; return 1; }
  rc=0; _bounded_capture 1 "$out" sleep 30 || rc=$?
  [ "$rc" -eq 124 ] || { echo "deadline -> $rc (must be 124, distinct from 0 and from the command's own status)"; return 1; }
}

@test "B. _bounded_capture's bound needs NO coreutils (the macOS half of the finding)" {
  # THE POINT of this primitive. `_bounded` execs timeout(1)/gtimeout(1) and runs
  # the bare command when neither exists — a documented no-op on a stock Mac — and
  # --diagnose is Darwin-reachable, where the cost of a call that never returns is
  # the whole bundle, not a stall (Bugbot High, client#984).
  #
  # Two assertions, because either alone is weak: the implementation must not
  # REACH FOR the coreutils binaries, and the deadline must actually fire with
  # them unavailable.
  local body rc=0 out="$BATS_TEST_TMPDIR/cap2"
  body="$(awk '/^_bounded_capture\(\)/{f=1} f{print} f&&/^\}/{exit}' "${LIB_DIR}/common.sh")"
  [ -n "$body" ] || return 1
  ! printf '%s\n' "$body" | grep -qE '(^|[^_[:alnum:]])(timeout|gtimeout)([^[:alnum:]]|$)' || {
    echo "_bounded_capture reaches for timeout/gtimeout — then it is _bounded with extra steps and inherits the same macOS no-op"
    printf '%s\n' "$body" | grep -nE '(timeout|gtimeout)'
    return 1
  }
  # Drive it with both binaries reported ABSENT and shadowed, so the deadline can
  # only come from the background-PID mechanism.
  has() { case "$1" in timeout|gtimeout) return 1 ;; *) return 0 ;; esac; }
  timeout()  { echo "COREUTILS-TIMEOUT-USED"; return 0; }
  gtimeout() { echo "COREUTILS-TIMEOUT-USED"; return 0; }
  _bounded_capture 1 "$out" sleep 30 || rc=$?
  [ "$rc" -eq 124 ] || { echo "the deadline did not fire without coreutils (rc=$rc)"; return 1; }
  ! grep -q 'COREUTILS-TIMEOUT-USED' "$out" || { echo "it used the coreutils path after all"; return 1; }
}

# ── C. the safe side, at the sites that PRINT rather than decide ────────────

@test "C. run_diagnose: a timed-out proxy read says UNKNOWN, never 'no proxy'" {
  # Bugbot, client#984. `docker inspect … | grep -iE PROXY` gave empty output on a
  # fired deadline — indistinguishable from a node that carries no proxy env, on a
  # machine being diagnosed FOR a proxy problem.
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { echo "k3d $*"; }
  # the node listing answers; every per-node inspect times out
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    case "$*" in
      *"ps -a"*)  printf 'k3d-tracebloc-server-0\n' > "$out"; return 0 ;;
      *inspect*)  : > "$out"; return 124 ;;
      *)          printf 'ok\n' > "$out"; return 0 ;;
    esac
  }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'proxy env UNKNOWN for this node, not absent' || {
    echo "a timed-out inspect did not say the proxy env is UNKNOWN"; return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'no PROXY variables in this node' || {
    echo "claimed the node has no PROXY variables after the read timed out"; return 1; }
}

@test "C. run_diagnose: a node that genuinely has no proxy env says THAT instead (not vacuous)" {
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { echo "k3d $*"; }
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    case "$*" in
      *"ps -a"*) printf 'k3d-tracebloc-server-0\n' > "$out"; return 0 ;;
      *inspect*) printf 'PATH=/usr/bin\nHOME=/root\n' > "$out"; return 0 ;;
      *)         printf 'ok\n' > "$out"; return 0 ;;
    esac
  }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'no PROXY variables in this node' || {
    echo "a successful read with no proxy vars did not say so"; return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'proxy env UNKNOWN' || {
    echo "claimed UNKNOWN on a read that completed"; return 1; }
}

@test "C. run_diagnose: a timed-out 'docker info' says so instead of an empty field list" {
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { echo "k3d $*"; }
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    case "$*" in
      *info*) : > "$out"; return 124 ;;
      *)      printf 'ok\n' > "$out"; return 0 ;;
    esac
  }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'docker info read did not complete' || {
    echo "an empty section stood in for a timed-out docker info"; return 1; }
}

# ── D. THE OTHER DIRECTION: a read that COMPLETED AND FAILED ────────────────
#
# saadqbal, client#984, and the third round of the same shape. Everything above
# guards "couldn't tell" being converted into an answer. This guards the mirror
# image: an answer converted into "couldn't tell". `_bounded_capture` returns the
# child's REAL exit code on completion and 124 only on the deadline, but all seven
# --diagnose call sites tested `if _bounded_capture …; then` and wrote the timeout
# sentence for ANY non-zero — discarding $_cap, which holds the error text.
#
# With the daemon live but the socket not permitting this user, `docker version`
# exits 1 in milliseconds printing "permission denied while trying to connect to
# the Docker daemon socket", and 00-host.txt recorded "(the docker server-version
# read did not complete within 10s)". The cause was in hand and thrown away.

@test "D. _bounded_capture_read: answered / deadline / FAILED are three different sections" {
  local out="$BATS_TEST_TMPDIR/d-cap" answered deadline failed
  # answered: prints NOTHING and returns 0 — the caller renders the capture.
  answered="$(_bounded_capture() { printf 'CONTENT\n' > "$2"; return 0; }
              _bounded_capture_read 10 "$out" "docker info read" docker info)" || {
    echo "a successful read must return 0"; return 1; }
  [ -z "$answered" ] || { echo "a successful read printed prose: $answered"; return 1; }

  local rc=0
  deadline="$( _bounded_capture() { : > "$2"; return 124; }
               _bounded_capture_read 10 "$out" "docker info read" docker info )" || rc=$?
  [ "$rc" -ne 0 ] || { echo "a fired deadline must not return 0"; return 1; }

  rc=0
  printf 'permission denied while trying to connect to the Docker daemon socket\n' > "$out"
  failed="$( _bounded_capture() { return 1; }
             _bounded_capture_read 10 "$out" "docker info read" docker info )" || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failed read must not return 0"; return 1; }

  # THE ASSERTION THAT MATTERS: the failure is not reported as a timeout, and it
  # carries the tool's own error text.
  printf '%s\n' "$deadline" | grep -q 'did not complete within' \
    || { echo "deadline -> $deadline"; return 1; }
  printf '%s\n' "$failed" | grep -q 'did not complete within' \
    && { echo "a read that ANSWERED with an error was reported as a timeout: $failed"; return 1; }
  printf '%s\n' "$failed" | grep -q 'permission denied while trying to connect' \
    || { echo "the error text was discarded: $failed"; return 1; }
  [ "$answered" != "$deadline" ] && [ "$deadline" != "$failed" ] || return 1
}

@test "D. _bounded_capture_read: 'could not capture' never renders the PREVIOUS read's output" {
  # _bounded_capture returns 2 when it cannot create the capture file — the command
  # never ran, and $_cap may still hold the output of the read before it. Printing
  # that would attribute one read's answer to another, in the artifact support reads
  # first. Disambiguated by whether the file is ours to write, so a command's own
  # exit 2 still gets its text printed.
  local out="$BATS_TEST_TMPDIR/d-nocap" got
  printf 'STALE-OUTPUT-FROM-THE-PREVIOUS-READ\n' > "$out"
  local rc=0
  got="$( _bounded_capture() { return 2; }
          _bounded_capture_read 10 "$out/unwritable" "k3d cluster listing" k3d cluster list )" || rc=$?
  [ "$rc" -ne 0 ] || { echo "an uncapturable read must not return 0"; return 1; }
  printf '%s\n' "$got" | grep -q 'STALE-OUTPUT' \
    && { echo "printed a previous read's output: $got"; return 1; }
  printf '%s\n' "$got" | grep -q 'did not complete within' \
    && { echo "an unattempted read was reported as a timeout: $got"; return 1; }
  # A command's OWN exit 2, on a writable capture, still surfaces its text.
  rc=0
  printf 'k3d: broken kubeconfig\n' > "$out"
  got="$( _bounded_capture() { return 2; }
          _bounded_capture_read 10 "$out" "k3d cluster listing" k3d cluster list )" || rc=$?
  printf '%s\n' "$got" | grep -q 'k3d: broken kubeconfig' \
    || { echo "a command's own exit 2 lost its error text: $got"; return 1; }
}

@test "D. _bounded_capture_read really is BOUNDED (the name is not the guarantee)" {
  # The name carries the word check-style rule 5 looks for, so it must delegate to
  # the coreutils-free primitive rather than merely be spelled like it does.
  local body
  body="$(awk '/^_bounded_capture_read\(\)/{f=1} f{print} f&&/^\}/{exit}' "${LIB_DIR}/diagnose.sh")"
  [ -n "$body" ] || { echo "_bounded_capture_read not found in diagnose.sh"; return 1; }
  printf '%s\n' "$body" | grep -qE '(^|[^_[:alnum:]])_bounded_capture[[:space:]]' \
    || { echo "_bounded_capture_read does not call _bounded_capture — the bound is a name only"; return 1; }
}

@test "D. census: EVERY --diagnose read site handles all three states, none open-codes the branch" {
  # The structural half. Fixing sites did not converge — the same conflation came
  # back three review rounds running — so the classification lives in ONE function
  # and this asserts that no call site is allowed to spell it again. If a new read
  # lands with its own `if _bounded_capture …; then … else "did not complete" fi`,
  # this reddens.
  local f="${LIB_DIR}/diagnose.sh" bad n
  bad="$(grep -nE '(^|[^_[:alnum:]])_bounded_capture[[:space:]]+"' "$f" \
         | grep -vE '_bounded_capture[[:space:]]+"\$secs"' || true)"
  [ -z "$bad" ] || {
    echo "read site(s) calling _bounded_capture directly instead of _bounded_capture_read — each one gets to collapse the three outcomes again:"
    printf '%s\n' "$bad"; return 1; }
  # …and the classifier is reached by as many sites as we think it is.
  n="$(grep -cE '(^|[^_[:alnum:]])_bounded_capture_read[[:space:]]' "$f" || true)"
  [ "$n" -ge 7 ] || {
    echo "only $n call site(s) route through _bounded_capture_read; 7 are known to exist, so this census has gone vacuous"
    grep -nE '_bounded_capture_read' "$f"; return 1; }
}

@test "D. run_diagnose: a socket-permission failure is recorded as the ERROR, not as a hang" {
  # saadqbal's concrete case, end to end through the real bundle. Daemon live, socket
  # not permitting this user: every read exits 1 in milliseconds with the reason on
  # stderr. The bundle must carry the reason.
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { echo "k3d $*"; }
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    printf 'permission denied while trying to connect to the Docker daemon socket\n' > "$out"
    return 1
  }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'permission denied while trying to connect' || {
    echo "the bundle threw away the actual cause"
    tar -xzOf "$tgz" 2>/dev/null | grep -n 'server-version\|did not complete' || true
    return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'did not complete within' || {
    echo "a read that answered in milliseconds was written into the bundle as a hang:"
    tar -xzOf "$tgz" 2>/dev/null | grep -n 'did not complete within'
    return 1; }
}

@test "D. run_diagnose: a k3d read that FAILS does not blame the engine" {
  # The worst of the seven. A k3d that exits non-zero on a broken kubeconfig or an
  # unreadable \$HOME/.k3d used to be written up as "the engine is not answering" —
  # a confident, wrong claim in the artifact support reads first.
  has() { return 0; }
  _docker_answers_bounded() { return 0; }
  kubectl() { printf 'kubectl %s\n' "$*"; }
  helm() { printf 'helm %s\n' "$*"; }
  k3d() { echo "k3d $*"; }
  _bounded_capture() {
    local secs="$1" out="$2"; shift 2
    case "$*" in
      *"cluster list"*) printf 'FATA[0000] unable to read kubeconfig\n' > "$out"; return 1 ;;
      *"ps -a"*)        printf 'k3d-tracebloc-server-0\n' > "$out"; return 0 ;;
      *)                printf 'ok\n' > "$out"; return 0 ;;
    esac
  }
  run run_diagnose
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  tgz="$(ls "$HOST_DATA_DIR"/tracebloc-diagnose-*.tgz 2>/dev/null | head -1)"
  [ -n "$tgz" ] || return 1
  tar -xzOf "$tgz" 2>/dev/null | grep -q 'unable to read kubeconfig' || {
    echo "the k3d error text was discarded"; return 1; }
  ! tar -xzOf "$tgz" 2>/dev/null | grep -q 'k3d cluster listing did not complete' || {
    echo "a k3d read that ANSWERED with an error was reported as a timeout"; return 1; }
}
