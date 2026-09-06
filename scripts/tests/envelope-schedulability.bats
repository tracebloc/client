#!/usr/bin/env bats
# The envelope-schedulability guard and the installer functions behind it,
# tested (backend#2870).
#
# The guard runs in DRIFT_GUARDS (the required `Source-of-truth drift` job), so
# per this repo's rule it must have a test of its own rather than only its own
# green run against the real tree (backend#1729). Its ability to go RED is proven
# by envelope-schedulability-mutations.sh, also in DRIFT_GUARDS; this file covers
# the pieces the guard composes -- the pod-level scheduler formula, the
# per-node measurement and its exclusions, the envelope-string reader, and the
# --print-footprint contract the derivation rests on.
#
# Every assertion ends in `|| return 1`: bats-hygiene.bats requires it, and on
# bash 3.2 a bare `[[ … ]]` as a test's last statement can pass vacuously.
load test_helper

setup() {
  load_lib install-client-helm.sh
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  GUARD="$HERE/envelope-schedulability.sh"
  FOOTPRINT="$HERE/control-plane-footprint.sh"
  TB_NAMESPACE=tracebloc
  has() { return 0; }
}

# ── the derivation contract ─────────────────────────────────────────────────

@test "control-plane-footprint.sh --print-footprint: stdout is exactly '<mem MiB> <cpu m>', prose goes to stderr" {
  local out err
  err="$(mktemp)"
  out="$(bash "$FOOTPRINT" --print-footprint 2>"$err")" || { cat "$err"; rm -f "$err"; return 1; }
  [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "stdout was: $out"; rm -f "$err"; return 1; }
  # The per-profile lines still exist -- on stderr.
  grep -q 'control plane requests' "$err" || { cat "$err"; rm -f "$err"; return 1; }
  rm -f "$err"
}

@test "control-plane-footprint.sh --print-footprint: the pair is the SAME sum the report prints" {
  # Drive both modes on a known fixture so the equality is about the arithmetic,
  # not about whatever the chart happens to render today.
  local fx; fx="$(mktemp)"
  cat > "$fx" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: a}
spec:
  replicas: 2
  template: {spec: {containers: [{name: c1, resources: {requests: {memory: 1Gi, cpu: 250m}}}]}}
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: b}
spec:
  template: {spec: {containers: [{name: c2, resources: {requests: {memory: 128Mi, cpu: 50m}}}]}}
YAML
  local pair
  pair="$(TB_CP_FOOTPRINT_FIXTURE="$fx" TB_CP_FOOTPRINT_MEM_CEIL=9999 TB_CP_FOOTPRINT_CPU_CEIL=9999 bash "$FOOTPRINT" --print-footprint 2>/dev/null)" || { rm -f "$fx"; return 1; }
  rm -f "$fx"
  [ "$pair" = "2176 550" ] || { echo "got '$pair'"; return 1; }
}

@test "control-plane-footprint.sh --print-footprint: a breached ratchet prints NOTHING on stdout and exits 1" {
  # A caller must never read a refused run as a number (fail closed). stderr is
  # dropped INSIDE the wrapper so $output is stdout alone -- the channel a caller
  # would `read`. (bats' `run` merges stderr itself, so a redirect on the `run`
  # line would not reach the guard.)
  run bash -c 'TB_CP_FOOTPRINT_MEM_CEIL=1 bash "$1" --print-footprint 2>/dev/null' _ "$FOOTPRINT"
  [ "$status" -eq 1 ] || { echo "rc=$status"; return 1; }
  [ -z "$output" ] || { echo "stdout was: $output"; return 1; }
}

@test "control-plane-footprint.sh: an unknown flag is refused, not ignored" {
  run bash "$FOOTPRINT" --print-footprnt
  [ "$status" -eq 2 ] || return 1
}

@test "gen-footprint-embed.sh --check: the embedded footprint equals the render (green today)" {
  run "$HERE/../gen-footprint-embed.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"footprint embed matches the chart render"* ]] || { echo "$output"; return 1; }
}

@test "gen-footprint-embed.sh --check: a drifted embed is reported as EMBED DRIFT, and the write mode repairs it" {
  # A COPY of the tree, so the real installer is never touched. The generator
  # derives from the chart in ITS OWN tree, so the copy needs the chart and the
  # footprint guard beside the installer.
  local td; td="$(mktemp -d)"
  mkdir -p "$td/scripts/lib" "$td/scripts/tests"
  cp -R "$HERE/../../client" "$td/client"
  cp "$HERE/../gen-footprint-embed.sh" "$td/scripts/"
  cp "$FOOTPRINT" "$td/scripts/tests/"
  sed 's/^_TB_CP_FOOTPRINT_MEM_BYTES=.*/_TB_CP_FOOTPRINT_MEM_BYTES=1/' "$HERE/../lib/install-client-helm.sh" > "$td/scripts/lib/install-client-helm.sh"
  run bash "$td/scripts/gen-footprint-embed.sh" --check
  [ "$status" -eq 1 ] || { echo "$output"; rm -rf "$td"; return 1; }
  [[ "$output" == *"EMBED DRIFT"*"_TB_CP_FOOTPRINT_MEM_BYTES=1"* ]] || { echo "$output"; rm -rf "$td"; return 1; }
  # Write mode repairs it, and --check is then green on the copy.
  run bash "$td/scripts/gen-footprint-embed.sh"
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$td"; return 1; }
  run bash "$td/scripts/gen-footprint-embed.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$td"; return 1; }
  # And the repaired value is the render's, not a hand-typed one: compare to the
  # real installer, which --check above proved matches the same chart.
  local want got
  want="$(grep '^_TB_CP_FOOTPRINT_MEM_BYTES=' "$HERE/../lib/install-client-helm.sh")"
  got="$(grep '^_TB_CP_FOOTPRINT_MEM_BYTES=' "$td/scripts/lib/install-client-helm.sh")"
  rm -rf "$td"
  [ "$want" = "$got" ] || { echo "want '$want' got '$got'"; return 1; }
}

@test "gen-footprint-embed.sh: a missing assignment is reported, not silently skipped" {
  local td; td="$(mktemp -d)"
  mkdir -p "$td/scripts/lib" "$td/scripts/tests"
  cp -R "$HERE/../../client" "$td/client"
  cp "$HERE/../gen-footprint-embed.sh" "$td/scripts/"
  cp "$FOOTPRINT" "$td/scripts/tests/"
  grep -v '^_TB_CP_FOOTPRINT_CPU_MILLI=' "$HERE/../lib/install-client-helm.sh" > "$td/scripts/lib/install-client-helm.sh"
  run bash "$td/scripts/gen-footprint-embed.sh" --check
  rm -rf "$td"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"no _TB_CP_FOOTPRINT_CPU_MILLI assignment"* ]] || { echo "$output"; return 1; }
}

# ── the guard itself ────────────────────────────────────────────────────────

@test "envelope-schedulability.sh: green on the real tree, and it counted cases" {
  run bash "$GUARD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"envelope-schedulability: OK"* ]] || { echo "$output"; return 1; }
  # It walked the golden vectors -- a guard that passes having checked nothing is
  # the class this repo catalogues. The table has 13 rows today; assert a floor,
  # not the exact count, so a vector added upstream does not redden this.
  [[ "$output" =~ ok\ +positive\ control:\ ([0-9]+)/([0-9]+) ]] || { echo "$output"; return 1; }
  [ "${BASH_REMATCH[2]}" -ge 10 ] || { echo "only ${BASH_REMATCH[2]} measurable vectors"; return 1; }
  [ "${BASH_REMATCH[1]}" -ge 1 ] || return 1
}

@test "envelope-schedulability.sh: CANNOT TELL (exit 2) when the tree has no chart to derive from" {
  local td; td="$(mktemp -d)"
  mkdir -p "$td/scripts/lib" "$td/scripts/tests/fixtures"
  cp "$HERE/../lib/common.sh" "$HERE/../lib/install-client-helm.sh" "$td/scripts/lib/"
  cp "$FOOTPRINT" "$td/scripts/tests/"
  cp "$HERE/fixtures/envelope_vectors.bash" "$td/scripts/tests/fixtures/"
  # no client/ -> the footprint guard refuses -> this guard must not pass
  TB_SCHED_ROOT="$td" run bash "$GUARD"
  rm -rf "$td"
  [ "$status" -eq 2 ] || { echo "rc=$status: $output"; return 1; }
  [[ "$output" == *"CANNOT TELL"* ]] || { echo "$output"; return 1; }
}

# ── the pieces: scheduler formula, measurement, exclusions, reader ──────────

@test "_pod_effective_requests: sum(app) vs max(init), per resource, the scheduler's formula" {
  # apps: 100Mi+200Mi = 300Mi, 100m+100m = 200m. inits: max(1000Mi,50Mi) = 1000Mi,
  # max(50m,500m) = 500m. Effective: 1000Mi / 500m -- NOT 1350Mi / 750m.
  local got
  got="$(_pod_effective_requests '100m/100Mi,100m/200Mi,' '50m/1000Mi,500m/50Mi,')"
  [ "$got" = "$(( 1000 * 1024 * 1024 )) 500" ] || { echo "got '$got'"; return 1; }
  # Init smaller than the app sum in one dimension only: memory from apps, cpu from init.
  got="$(_pod_effective_requests '100m/300Mi,' '900m/10Mi,')"
  [ "$got" = "$(( 300 * 1024 * 1024 )) 900" ] || { echo "got '$got'"; return 1; }
}

@test "_pod_effective_requests: an unparseable quantity yields NOTHING, never zero" {
  run _pod_effective_requests '100m/lots,' ''
  [ -z "$output" ] || return 1
  run _pod_effective_requests 'many/70Mi,' ''
  [ -z "$output" ] || return 1
  # Absent requests are legitimately zero, and decimal SI / fractional cores parse.
  run _pod_effective_requests '/,' ''
  [ "$output" = "0 0" ] || return 1
  run _pod_effective_requests '0.5/250M,' ''
  [ "$output" = "250000000 500" ] || return 1
}

@test "_measured_system_requests: per-node sums, MAX across nodes" {
  kubectl() {
    case "$*" in
      *"get namespaces"*) printf 'kube-system|\ntracebloc|tracebloc\n' ;;
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|\nkube-system|Running|b|100m/70Mi,|\nkube-system|Running|b|100m/70Mi,|\n' ;;
      *) return 1 ;;
    esac
  }
  _measured_system_requests || return 1
  # node b carries two pods (140Mi / 200m); node a one. The max is b, not the
  # cluster total (210Mi / 300m).
  [ "$_TB_SYS_MEM_BYTES" -eq $(( 140 * 1024 * 1024 )) ] || { echo "$_TB_SYS_MEM_BYTES"; return 1; }
  [ "$_TB_SYS_CPU_MILLI" -eq 200 ] || return 1
  [[ "$_TB_SYS_NOTE" == *"3 pod(s) across 2 node(s)"* ]] || { echo "$_TB_SYS_NOTE"; return 1; }
}

@test "_measured_system_requests: excludes the release namespace, release-owned namespaces, terminal and unscheduled pods" {
  kubectl() {
    case "$*" in
      *"get namespaces"*) printf 'kube-system|\ntracebloc|tracebloc\ntracebloc-node-agents|tracebloc\nother|someone-else\n' ;;
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|\ntracebloc|Running|a|1/4Gi,|\ntracebloc-node-agents|Running|a|1/1Gi,|\nkube-system|Succeeded|a|1/1Gi,|\nkube-system|Failed|a|1/1Gi,|\nkube-system|Pending||1/1Gi,|\nother|Running|a|100m/30Mi,|\n' ;;
      *) return 1 ;;
    esac
  }
  _measured_system_requests || return 1
  # kube-system 70Mi + `other` 30Mi (owned by a DIFFERENT release, so it counts) = 100Mi / 200m.
  [ "$_TB_SYS_MEM_BYTES" -eq $(( 100 * 1024 * 1024 )) ] || { echo "$_TB_SYS_MEM_BYTES"; return 1; }
  [ "$_TB_SYS_CPU_MILLI" -eq 200 ] || return 1
}

@test "_measured_system_requests: init containers of a running pod still count via max()" {
  # A pod whose init container asked for more than its app containers keeps that
  # reservation for its whole life -- the scheduler reserved max(), not sum(app).
  kubectl() {
    case "$*" in
      *"get namespaces"*) printf 'kube-system|\n' ;;
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|200m/500Mi,\n' ;;
      *) return 1 ;;
    esac
  }
  _measured_system_requests || return 1
  [ "$_TB_SYS_MEM_BYTES" -eq $(( 500 * 1024 * 1024 )) ] || return 1
  [ "$_TB_SYS_CPU_MILLI" -eq 200 ] || return 1
}

@test "_measured_system_requests: an unreadable pod list is NOT a footprint of zero" {
  kubectl() { case "$*" in *"get namespaces"*) printf 'kube-system|\n' ;; *) return 1 ;; esac; }
  run _measured_system_requests
  [ "$status" -eq 1 ] || return 1
  _measured_system_requests || true
  [[ "$_TB_SYS_NOTE" == *"pod list could not be read"* ]] || { echo "$_TB_SYS_NOTE"; return 1; }
}

@test "_measured_system_requests: a quantity it cannot parse makes the measurement unusable, and names the pod's namespace" {
  kubectl() {
    case "$*" in
      *"get namespaces"*) printf 'kube-system|\n' ;;
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|\nweird-ns|Running|a|100m/1.5Gi,|\n' ;;
      *) return 1 ;;
    esac
  }
  run _measured_system_requests
  [ "$status" -eq 1 ] || return 1
  _measured_system_requests || true
  [[ "$_TB_SYS_NOTE" == *"weird-ns"*"cannot parse"* ]] || { echo "$_TB_SYS_NOTE"; return 1; }
}

@test "_measured_system_requests: unreadable namespace ownership still measures, excluding only the release namespace, and says so" {
  kubectl() {
    case "$*" in
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|\ntracebloc|Running|a|1/4Gi,|\ntracebloc-node-agents|Running|a|100m/512Mi,|\n' ;;
      *) return 1 ;;
    esac
  }
  _measured_system_requests || return 1
  # node-agents can no longer be attributed to the release, so it is COUNTED
  # (the conservative direction) -- 70Mi + 512Mi.
  [ "$_TB_SYS_MEM_BYTES" -eq $(( 582 * 1024 * 1024 )) ] || { echo "$_TB_SYS_MEM_BYTES"; return 1; }
  [[ "$_TB_SYS_NOTE" == *"namespace ownership unreadable"* ]] || { echo "$_TB_SYS_NOTE"; return 1; }
}

@test "_envelope_dimension: case-insensitive keys, trimmed pairs, absent key is empty" {
  [ "$(_envelope_dimension 'cpu=7, Memory=29Gi' memory)" = "29Gi" ] || return 1
  [ "$(_envelope_dimension ' CPU=7 ,memory=29Gi' cpu)" = "7" ] || return 1
  [ -z "$(_envelope_dimension 'memory=29Gi' cpu)" ] || return 1
  # A dimension that merely STARTS with cpu is not cpu.
  [ -z "$(_envelope_dimension 'cpuset=7,memory=29Gi' cpu)" ] || return 1
}

@test "_cpu_to_milli / _mem_to_bytes: the extended grammar, and junk is still empty" {
  [ "$(_cpu_to_milli 0.5)" = "500" ] || return 1
  [ "$(_cpu_to_milli 1.2345)" = "1234" ] || return 1     # floored, never rounded up
  [ "$(_cpu_to_milli 1.05)" = "1050" ] || return 1       # 050 is not octal
  [ -z "$(_cpu_to_milli eight)" ] || return 1
  [ -z "$(_cpu_to_milli 1.x)" ] || return 1
  [ "$(_mem_to_bytes 250M)" = "250000000" ] || return 1
  [ "$(_mem_to_bytes 5k)" = "5000" ] || return 1
  [ "$(_mem_to_bytes 1Ti)" = "1099511627776" ] || return 1
  [ -z "$(_mem_to_bytes lots)" ] || return 1
  [ -z "$(_mem_to_bytes 64GB)" ] || return 1
  [ -z "$(_mem_to_bytes Gi)" ] || return 1
}

@test "_fit_training_envelope: emits NOTHING on stdout (it would corrupt a captured value)" {
  kubectl() {
    case "$*" in
      *"get nodes"*) printf '4 8Gi\n' ;;
      *"get namespaces"*) printf 'kube-system|\n' ;;
      *"get pods"*) printf 'kube-system|Running|a|100m/70Mi,|\n' ;;
      *) return 1 ;;
    esac
  }
  helm() { return 1; }
  unset TRACEBLOC_TRAINING_RESOURCES
  # ONE system pod here (70Mi / 100m), so cpu fits (3000 + 900 + 100 = 4000) and
  # only memory reduces (5120 + 3136 + 70 > 8192 -> 4 GiB): cpu=3,memory=4Gi.
  # Anything else in the capture -- a stray echo -- would corrupt the value.
  local captured
  captured="$(_resolve_training_size; _fit_training_envelope; printf '%s' "$_TB_TRAINING_SIZE")"
  [ "$captured" = "cpu=3,memory=4Gi" ] || { echo "captured '$captured'"; return 1; }
}
