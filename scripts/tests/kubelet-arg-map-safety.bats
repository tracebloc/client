#!/usr/bin/env bats
# kubelet-arg-map-safety.sh — the guard that keeps map-valued kubelet settings off
# the command line (backend#2460).
#
# Every case here drives the REAL script against a fixture tree via
# TB_KUBELET_ARG_ROOT, rather than re-implementing the rule. A test that carries
# its own copy of the regex proves that a regex nobody runs would have caught the
# bug — the failure mode backend#1729 catalogues.
#
# The fixtures are two-line stand-ins for the installers, not copies of them:
# what is under test is the guard, and a real 6,000-line installer in a fixture
# would make every case fragile against edits that have nothing to do with it.
# The live tree is exercised separately, by the last two cases.

load test_helper

setup() {
  GUARD="${SCRIPTS_DIR}/tests/kubelet-arg-map-safety.sh"
  FIX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FIX/scripts/lib" || return 1
}

# Write a fixture pair. $1 -> cluster.sh body, $2 -> install-k8s.ps1 body.
_fixture() {
  printf '%s\n' "$1" > "$FIX/scripts/lib/cluster.sh" || return 1
  printf '%s\n' "$2" > "$FIX/scripts/install-k8s.ps1" || return 1
}

_run_guard() {
  run env TB_KUBELET_ARG_ROOT="$FIX" bash "$GUARD"
}

SAFE_BASH='  K3D_ARGS+=(--k3s-arg "--kubelet-arg=fail-cgroupv1=false@all")'
SAFE_PS1='      $k3dArgs += @("--k3s-arg", "--kubelet-arg=fail-cgroupv1=false@all")'

@test "the allowlisted scalar passes on both twins" {
  _fixture "$SAFE_BASH" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- the trap this guard exists for ----------------------------------------

@test "eviction-hard on the bash twin is a violation" {
  _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=eviction-hard=memory.available<500Mi@all\")" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"cluster.sh passes eviction-hard"* ]] || { echo "$output"; return 1; }
}

@test "eviction-hard on the PowerShell twin is a violation" {
  _fixture "$SAFE_BASH" "$SAFE_PS1
      \$k3dArgs += @(\"--k3s-arg\", \"--kubelet-arg=eviction-hard=memory.available<500Mi@all\")"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"install-k8s.ps1 passes eviction-hard"* ]] || { echo "$output"; return 1; }
}

@test "the eviction-hard message names the thresholds that get deleted" {
  # The finding has to teach, not just refuse. Someone hitting this has a plain
  # goal -- reserve memory -- and needs to learn WHY the obvious flag is wrong,
  # or they will reach for --kubelet-arg again in a different spelling.
  _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=eviction-hard=memory.available<500Mi@all\")" "$SAFE_PS1"
  _run_guard
  [[ "$output" == *"imagefs.available"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"nodefs.available"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"drop-in"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"2460"* ]] || { echo "$output"; return 1; }
}

@test "kube-reserved and system-reserved are violations too" {
  for setting in kube-reserved system-reserved; do
    _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=${setting}=cpu=200m,memory=512Mi@all\")" "$SAFE_PS1"
    _run_guard
    [ "$status" -eq 1 ] || { echo "$setting: $output"; return 1; }
    [[ "$output" == *"$setting is map-valued"* ]] || { echo "$setting: $output"; return 1; }
  done
}

@test "an unknown kubelet arg is refused, not waved through" {
  # The allowlist is a list of what is PERMITTED for exactly this reason: the next
  # map-valued kubelet setting is the one nobody thought to denylist.
  _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=some-future-map=a=1,b=2@all\")" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"some-future-map"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"not on the allowlist"* ]] || { echo "$output"; return 1; }
}

@test "a dotted kubelet arg name is parsed whole, not truncated at the dot" {
  # If the name charset missed '.', the parser would read 'feature' and report a
  # finding about a setting that does not exist -- or match an allowlist entry it
  # should not. Either way the guard would be lying about what it read.
  _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=node.status.max-images=5@all\")" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"node.status.max-images"* ]] || { echo "$output"; return 1; }
}

# --- the two installers must agree -----------------------------------------

@test "an allowlisted arg dropped from one twin is still a finding" {
  # Both sides are individually allowlist-clean here, so this is NOT check 1
  # restated: one platform would ship a differently-configured kubelet, and the
  # gate on this flag is version-dependent, so the drop is easy to miss.
  _fixture "$SAFE_BASH" '      # nothing here'
  _run_guard
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

# --- fail closed ------------------------------------------------------------

@test "a file that passes no kubelet args at all fails CLOSED, not green" {
  # Zero parsed args satisfy an allowlist vacuously. A stale parser would then
  # report a clean sweep over a file it can no longer read -- the fail-OPEN shape
  # this repo keeps finding (backend#1729).
  _fixture '  # no kubelet args here' "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"parsed NO"* ]] || { echo "$output"; return 1; }
}

@test "an unreadable installer fails CLOSED" {
  _fixture "$SAFE_BASH" "$SAFE_PS1"
  rm -f "$FIX/scripts/install-k8s.ps1" || return 1
  _run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
}

# --- the guard must not fire on prose --------------------------------------

@test "a commented-out violation is not a finding" {
  # Both installers document the flags they pass, and this guard's own header
  # names every forbidden setting. A check that reads prose fires on its own
  # documentation -- which k3s-components-agreement.sh learned the hard way.
  _fixture "$SAFE_BASH
  # Never do this: --kubelet-arg=eviction-hard=memory.available<500Mi@all" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a violation with a trailing comment IS still a finding" {
  # The comment stripper drops whole comment lines only. Cutting from the first
  # '#' anywhere would also cut a '#' inside a string literal and could swallow a
  # real flag -- under-reporting, the fail-open direction. This pins the
  # deliberate choice to be wrong in the safe direction instead.
  _fixture "$SAFE_BASH
  K3D_ARGS+=(--k3s-arg \"--kubelet-arg=eviction-hard=memory.available<500Mi@all\") # temporary" "$SAFE_PS1"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# --- the live tree ----------------------------------------------------------

@test "the real installers are clean today" {
  run bash "$GUARD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the real installers do pass fail-cgroupv1, so the live run is not vacuous" {
  # Without this, the case above would keep passing if both installers stopped
  # passing kubelet args and the guard's fail-closed check regressed at the same
  # time. It also documents WHY the allowlist has an entry at all.
  run bash "$GUARD"
  [[ "$output" == *"fail-cgroupv1"* ]] || { echo "$output"; return 1; }
}
