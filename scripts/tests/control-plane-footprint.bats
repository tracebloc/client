#!/usr/bin/env bats
# The control-plane-footprint guard, tested (backend#2870).
#
# The guard runs in DRIFT_GUARDS (the required `Source-of-truth drift` job), so
# per this repo's rule it must have a test of its own rather than only its own
# green run against the real tree (backend#1729). Two things are exercised:
#
#   1  the summer (sum_control_plane_requests.py) parses a KNOWN manifest to a
#      known total -- Gi->MiB, DaemonSet counted x1, Deployment x replicas, and
#      Job/CronJob EXCLUDED. This is the arithmetic the whole guard rests on, and
#      helm is not needed to test it: it reads rendered YAML on stdin.
#   2  the guard's RATCHET and FAIL-CLOSED branches, driven through the real
#      script via TB_CP_FOOTPRINT_ROOT / the ceiling overrides -- never a copy.

setup() {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SUMMER="$HERE/sum_control_plane_requests.py"
  GUARD="$HERE/control-plane-footprint.sh"
}

# A manifest with one of each shape, so the exclusions and multipliers are all
# exercised by a total that is wrong under any one of them.
fixture() {
  cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: a}
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: c1
          resources: {requests: {memory: 1Gi, cpu: 250m}}
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: b}
spec:
  template:
    spec:
      containers:
        - name: c2
          resources: {requests: {memory: 128Mi, cpu: 50m}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: hook}
spec:
  template:
    spec:
      containers:
        - name: probe
          resources: {requests: {memory: 512Mi, cpu: 500m}}
YAML
}

@test "summer: Gi->MiB, Deployment x replicas, DaemonSet x1, Job excluded" {
  # Deployment 1Gi x2 = 2048 MiB, 250m x2 = 500m ; DaemonSet 128 MiB / 50m x1
  # Job (512 MiB / 500m) MUST NOT count. Expected: 2176 MiB / 550 m / 2 containers.
  local f; f="$(mktemp)"; fixture > "$f"
  run bash -c "python3 '$SUMMER' < '$f'"
  rm -f "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "2176 550 2" ]
}

@test "summer: an empty render sums to zero containers (the guard treats that as a finding)" {
  run bash -c "printf '' | python3 '$SUMMER'"
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 0" ]
}

@test "guard: the real render is at or under the recorded ceiling (green today)" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"control-plane-footprint: OK"* ]]
}

@test "guard: RATCHET reddens when the footprint would exceed the ceiling" {
  TB_CP_FOOTPRINT_MEM_CEIL=3000 run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exceed the recorded ceiling"* ]]
}

@test "guard: it reports the gap against the reserve, not asserts schedulability" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVER"* || "$output" == *"headroom"* ]]
}

@test "guard: FAIL-CLOSED when the installer reserve cannot be read" {
  root="$(mktemp -d)"
  mkdir -p "$root/client/ci" "$root/scripts/lib"
  cp -r "$HERE/../../client/." "$root/client/" 2>/dev/null || true
  : > "$root/scripts/lib/install-client-helm.sh"   # present but carries no reserve constant
  TB_CP_FOOTPRINT_ROOT="$root" run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read _TB_ENVELOPE_OVERHEAD"* ]]
  rm -rf "$root"
}
