#!/usr/bin/env bats
# The control-plane-footprint guard, tested (backend#2870).
#
# The guard runs in DRIFT_GUARDS (the required `Source-of-truth drift` job), so
# per this repo's rule it must have a test of its own rather than only its own
# green run against the real tree (backend#1729).
#
# Every assertion ends in `|| return 1`: bats-hygiene.bats requires it, and on
# bash 3.2 a bare `[[ … ]]` as a test's last statement can pass vacuously.
#
# The ARITHMETIC is driven through TB_CP_FOOTPRINT_FIXTURE -- a known manifest fed
# to the real guard in place of a helm render -- so the sum (Gi->MiB, replicas,
# DaemonSet x1, Job excluded) is exercised without helm. The RATCHET and
# FAIL-CLOSED branches are driven through the real script via its env overrides.

setup() {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  GUARD="$HERE/control-plane-footprint.sh"
}

# One of each shape, so the exclusions and multipliers all matter: Deployment 1Gi
# x2 = 2048 MiB / 500m ; DaemonSet 128 MiB / 50m x1 DESPITE carrying `replicas: 3`
# ; Job (512 MiB / 500m) EXCLUDED.
# Expected steady-state total: 2176 MiB / 550 m across 2 requesting containers.
# Drop the DaemonSet special case and it becomes 2432 / 650 -- which is what makes
# the `x1` in this test's name a claim the fixture can actually falsify.
write_fixture() {
  cat > "$1" <<'YAML'
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
  # A STRAY `replicas`, deliberately (Bugbot, #944). A DaemonSet has no replica
  # count -- but this fixture carries one so the `x1` arm is actually TESTED.
  # Without it the guard's DaemonSet branch and its missing-replicas fallback
  # both yield 1, so deleting the special case changed nothing and the arm the
  # test name advertises was pinned by nothing at all.
  #
  # With `replicas: 3` here the two disagree: the special case still counts the
  # DaemonSet ONCE (total unchanged at 2176/550), while the fallback would count
  # it three times (2432 MiB / 650 m). The expected total below is therefore the
  # assertion that the special case is present and doing the work.
  replicas: 3
  template: {spec: {containers: [{name: c2, resources: {requests: {memory: 128Mi, cpu: 50m}}}]}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: hook}
spec:
  template: {spec: {containers: [{name: probe, resources: {requests: {memory: 512Mi, cpu: 500m}}}]}}
YAML
}

@test "arithmetic: Gi->MiB, Deployment x replicas, DaemonSet x1, Job excluded" {
  local fx; fx="$(mktemp)"; write_fixture "$fx"
  # A ceiling above the fixture total keeps the ratchet green; we assert the SUM.
  TB_CP_FOOTPRINT_FIXTURE="$fx" TB_CP_FOOTPRINT_MEM_CEIL=9999 TB_CP_FOOTPRINT_CPU_CEIL=9999 run bash "$GUARD"
  rm -f "$fx"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q '2176 MiB / 550 m' || { echo "wrong sum: $output"; return 1; }
}

@test "arithmetic: init containers are max()'d against the app sum, not added to it" {
  # THE SCHEDULER'S FORMULA (@aptracebloc on client#944). A pod's effective request
  # per resource is max( sum(app containers), max(init containers) ) -- init
  # containers run to completion one at a time BEFORE the app containers, so they
  # are never resident alongside them. Summing them both inflates the figure this
  # guard hands to backend#2460/#2461.
  #
  # THIS FIXTURE EXISTS BECAUSE THE REAL CHART CANNOT TELL THE TWO APART. On the
  # live render the number is 3136 MiB either way -- the chart's init containers
  # carry no requests -- so the fix is INERT there and a green run proves nothing
  # about the formula. Here the two answers differ, deliberately:
  #
  #   app containers  : 100Mi + 200Mi = 300Mi ,  100m + 100m = 200m
  #   init containers : max(1000Mi, 50Mi) = 1000Mi , max(50m, 500m) = 500m
  #   sum-everything  : 1350 MiB / 750 m   <- the old, wrong answer
  #   scheduler       : max(300,1000)=1000 MiB , max(200,500)=500 m
  #
  # And it is PER-RESOURCE: memory comes from the init side, cpu also from the init
  # side here, but a fixture where they came from opposite sides would pass equally
  # -- which is why both numbers are asserted rather than a single total.
  local fx; fx="$(mktemp)"
  cat > "$fx" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: cp}
spec:
  replicas: 1
  template:
    spec:
      initContainers:
        - name: migrate
          resources: {requests: {memory: 1000Mi, cpu: 50m}}
        - name: seed
          resources: {requests: {memory: 50Mi, cpu: 500m}}
      containers:
        - name: api
          resources: {requests: {memory: 100Mi, cpu: 100m}}
        - name: sidecar
          resources: {requests: {memory: 200Mi, cpu: 100m}}
YAML
  TB_CP_FOOTPRINT_FIXTURE="$fx" TB_CP_FOOTPRINT_MEM_CEIL=9999 TB_CP_FOOTPRINT_CPU_CEIL=9999 run bash "$GUARD"
  rm -f "$fx"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # 1000 MiB / 500 m -- NOT 1350 / 750. Asserting the exact pair is what separates
  # the two formulas; "under the ceiling" would pass on both.
  printf '%s\n' "$output" | grep -q '1000 MiB / 500 m' || {
    echo "expected 1000 MiB / 500 m (scheduler formula), got: $output"; return 1; }
}

@test "arithmetic: decimal-SI and plain-byte quantities are summed, not counted as zero" {
  # 250M (decimal) = 238 MiB, 268435456 bytes = 256 MiB, on a DaemonSet (x1).
  # The old Ki|Mi|Gi|Ti-only parser returned 0 for both -- an undercount that
  # slips the ratchet (Bugbot, backend#2870). Total: 238 + 256 = 494 MiB.
  local fx; fx="$(mktemp)"
  cat > "$fx" <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: dec}
spec:
  template: {spec: {containers: [{name: c, resources: {requests: {memory: "250M"}}}]}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: bytes}
spec:
  template: {spec: {containers: [{name: c, resources: {requests: {memory: "268435456"}}}]}}
YAML
  TB_CP_FOOTPRINT_FIXTURE="$fx" TB_CP_FOOTPRINT_MEM_CEIL=9999 TB_CP_FOOTPRINT_CPU_CEIL=9999 run bash "$GUARD"
  rm -f "$fx"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q '494 MiB' || { echo "wrong sum: $output"; return 1; }
}

@test "arithmetic: an UNPARSEABLE quantity fails closed, never sums to zero" {
  local fx; fx="$(mktemp)"
  cat > "$fx" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: bad}
spec:
  template: {spec: {containers: [{name: c, resources: {requests: {memory: "25Xy"}}}]}}
YAML
  TB_CP_FOOTPRINT_FIXTURE="$fx" run bash "$GUARD"
  rm -f "$fx"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'cannot parse' || { echo "$output"; return 1; }
}

@test "guard: the real render is at or under the recorded ceiling (green today)" {
  run bash "$GUARD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q 'control-plane-footprint: OK' || { echo "$output"; return 1; }
}

@test "guard: RATCHET reddens when the footprint would exceed the ceiling" {
  TB_CP_FOOTPRINT_MEM_CEIL=3000 run bash "$GUARD"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'exceed the recorded ceiling' || { echo "$output"; return 1; }
}

@test "guard: it reports the gap against the reserve, not asserts schedulability" {
  run bash "$GUARD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE 'OVER|headroom' || { echo "$output"; return 1; }
}

@test "guard: FAIL-CLOSED when a render exits non-zero (partial/failed helm)" {
  # A fixture path that does not exist makes `cat` in _render_profile exit non-zero,
  # standing in for a failed helm render -- which must refuse, not undercount.
  TB_CP_FOOTPRINT_FIXTURE="/no/such/manifest.$$" run bash "$GUARD"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  printf '%s\n' "$output" | grep -q 'exited non-zero' || { echo "$output"; return 1; }
}

@test "guard: FAIL-CLOSED when the installer reserve cannot be read" {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/client/ci" "$root/scripts/lib"
  cp -r "$HERE/../../client/." "$root/client/" 2>/dev/null || true
  : > "$root/scripts/lib/install-client-helm.sh"   # present but carries no reserve constant
  TB_CP_FOOTPRINT_ROOT="$root" run bash "$GUARD"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; rm -rf "$root"; return 1; }
  printf '%s\n' "$output" | grep -q 'could not read _TB_ENVELOPE_OVERHEAD' || { echo "$output"; rm -rf "$root"; return 1; }
  rm -rf "$root"
}
