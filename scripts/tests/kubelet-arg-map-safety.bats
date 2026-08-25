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

@test "the two installers disagreeing produces the PARITY finding, by name" {
  # THE POINT OF ASSERTING THE MESSAGE, not just a non-zero status: an earlier
  # version of this test set the ps1 fixture to a bare comment, which code_of
  # strips to empty, so the guard fail_closed'd (exit 2) BEFORE the parity branch
  # ran -- and `status -ne 0` could not tell that apart from the exit 1 parity
  # gives. Check 2 could be deleted outright and the suite stayed green: vacuous,
  # by this suite's own standard. Found in review by @saqlainsyed007.
  #
  # Both fixtures are non-empty so the parse succeeds and execution reaches
  # check 2. Check 1 also fires here (ps1's extra arg is not allowlisted) and
  # that is unavoidable: with one entry on the allowlist there is no way for two
  # DIFFERENT non-empty arg sets to both be allowlist-clean. Hence the assertion
  # on the parity text specifically -- it is what distinguishes the two checks.
  _fixture "$SAFE_BASH" "$SAFE_PS1
      \$k3dArgs += @(\"--k3s-arg\", \"--kubelet-arg=some-other-setting=1@all\")"
  _run_guard
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"pass different kubelet args"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"installer_parity.json"* ]] || { echo "$output"; return 1; }
}

@test "the parity finding lists BOTH sides, so a reviewer knows which twin to open" {
  _fixture "$SAFE_BASH" "$SAFE_PS1
      \$k3dArgs += @(\"--k3s-arg\", \"--kubelet-arg=some-other-setting=1@all\")"
  _run_guard
  [[ "$output" == *"cluster.sh     : fail-cgroupv1"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"install-k8s.ps1: fail-cgroupv1 some-other-setting"* ]] || { echo "$output"; return 1; }
}

@test "an allowlisted arg dropped from one twin fails CLOSED, not as a parity finding" {
  # The realistic shape of a one-sided drop, and the guard classifies it as a
  # stale-parse rather than a disagreement -- because a file that passes no
  # kubelet args at all cannot be distinguished from a parser that stopped
  # matching. Pinned so the classification is a choice on the record: exit 2 with
  # "parsed NO", which sends a human to look, not exit 1 blaming parity.
  _fixture "$SAFE_BASH" '      # nothing here'
  _run_guard
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"parsed NO"* ]] || { echo "$output"; return 1; }
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
  #
  # ASSERTED AGAINST THE PER-INSTALLER LINES, not a bare substring. The guard also
  # prints `allowed as a CLI arg: fail-cgroupv1` unconditionally, straight out of
  # SAFE_KUBELET_ARGS -- so a bare `*"fail-cgroupv1"*` matched the allowlist echo
  # and would have held even if NEITHER installer passed anything. That is the
  # exact vacuity this test exists to rule out, in the test meant to rule it out
  # (Bugbot, Medium). The two lines below are printed from the PARSED sets, so they
  # cannot be satisfied by the allowlist.
  run bash "$GUARD"
  [[ "$output" == *"cluster.sh    fail-cgroupv1"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"install-k8s.ps1   fail-cgroupv1"* ]] || { echo "$output"; return 1; }
}

@test "an empty allowlist cannot make the live-run assertion pass on its own" {
  # Direct proof of the above, rather than an argument for it: blank the allowlist
  # in a copy of the guard and the per-installer lines still carry fail-cgroupv1
  # (parsed), while the `allowed as a CLI arg:` line goes empty. If the assertions
  # in the test above were reading the allowlist, this is where that shows.
  cp "$GUARD" "$BATS_TEST_TMPDIR/g.sh" || return 1
  sed -i.bak 's/^SAFE_KUBELET_ARGS=.*/SAFE_KUBELET_ARGS=""/' "$BATS_TEST_TMPDIR/g.sh" || return 1
  # Pointed at the real repo, since the copy would otherwise resolve `root` from
  # its own location in the tmpdir and fail closed on unreadable installers.
  run env TB_KUBELET_ARG_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)" bash "$BATS_TEST_TMPDIR/g.sh"
  [[ "$output" == *"cluster.sh    fail-cgroupv1"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"install-k8s.ps1   fail-cgroupv1"* ]] || { echo "$output"; return 1; }
  # And with nothing permitted, the guard REPORTS -- which pins that the allowlist
  # is load-bearing rather than decorative.
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}
