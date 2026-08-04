#!/usr/bin/env bats
# check-facts.sh (#435): scripts/spec/facts.env is the single source of truth for
# cross-OS installer facts (tool version pins), stamped into every consumer (bash
# common.sh, PowerShell install-k8s.ps1). --check is the CI gate that makes the #410
# incident — a pin bumped in one OS path but not the other — a red check. These tests
# run the REAL script against a throwaway repo copy so a bad pattern can't pass silently.
load test_helper

setup() {
  CF="${SCRIPTS_DIR}/check-facts.sh"
  # A minimal throwaway repo the script operates on via DRIFT-free cwd. check-facts.sh
  # resolves paths relative to its own location, so run the copied tree's script.
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/scripts/spec" "$REPO/scripts/lib"
  cp "$CF" "$REPO/scripts/check-facts.sh"
  cp "${SCRIPTS_DIR}/spec/facts.env" "$REPO/scripts/spec/facts.env"
  # Consumers seeded to match the spec (v5.9.0 / v4.2.3 / v1.29.4-k3s1).
  cat > "$REPO/scripts/lib/common.sh" <<'SH'
K8S_VERSION="${K8S_VERSION:-v1.29.4-k3s1}"
K3D_VERSION="${K3D_VERSION:-v5.9.0}"
HELM_VERSION="${HELM_VERSION:-v4.2.3}"
SH
  cat > "$REPO/scripts/install-k8s.ps1" <<'PS'
$script:K3dVersion  = if ($env:K3D_VERSION)  { $env:K3D_VERSION }  else { "v5.9.0" }
$script:HelmVersion = if ($env:HELM_VERSION) { $env:HELM_VERSION } else { "v4.2.3" }
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "v1.29.4-k3s1" }
$ReadyTimeout     = if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "300" }
PS
  cat > "$REPO/scripts/lib/summary.sh" <<'SH'
READY_TIMEOUT="${READY_TIMEOUT:-300}"
SH
}

_facts() { bash "$REPO/scripts/check-facts.sh" "$@"; }
_set_spec() { local tmp; tmp="$(mktemp)"; sed "s|^$1=.*|$1=$2|" "$REPO/scripts/spec/facts.env" > "$tmp" && mv "$tmp" "$REPO/scripts/spec/facts.env"; }

@test "check-facts --check: all consumers match the spec -> passes (#435)" {
  run _facts --check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"all installer facts match"* ]] || return 1
}

@test "check-facts --check: K8S_VERSION drift in PowerShell (not just bash) -> RED (#435 Bugbot)" {
  # install-k8s.ps1 pins K8S_VERSION too (--image rancher/k3s:$K8S_VERSION), so the spec
  # must enforce it in BOTH consumers — bumping bash alone can't leave Windows stale.
  local tmp; tmp="$(mktemp)"
  sed 's|"v1.29.4-k3s1"|"v1.30.0-k3s1"|' "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:K8S_VERSION"* ]] || return 1
}

@test "check-facts --write: a K8S_VERSION bump stamps BOTH bash and PowerShell (#435 Bugbot)" {
  _set_spec K8S_VERSION v1.31.0-k3s1
  _facts --write
  grep -q 'K8S_VERSION="${K8S_VERSION:-v1.31.0-k3s1}"' "$REPO/scripts/lib/common.sh"   # bash
  grep -q 'else { "v1.31.0-k3s1" }' "$REPO/scripts/install-k8s.ps1"                     # PowerShell
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts --check: #410 incident — bash pin bumped, PowerShell NOT -> RED (#435)" {
  # Simulate the real #410: someone bumps K3D in common.sh but forgets install-k8s.ps1.
  # The spec is authoritative, so BOTH the bumped bash and the stale ps1 must be caught.
  local tmp; tmp="$(mktemp)"
  sed 's|v5.9.0|v5.9.9|' "$REPO/scripts/lib/common.sh" > "$tmp" && mv "$tmp" "$REPO/scripts/lib/common.sh"
  run _facts --check
  [ "$status" -ne 0 ] || return 1   # red CI check
  [[ "$output" == *"common.sh:K3D_VERSION"* ]] || return 1
  [[ "$output" == *"drifted"* ]] || return 1
}

@test "check-facts --check: PowerShell pin drifts from bash+spec -> RED (#435)" {
  local tmp; tmp="$(mktemp)"
  sed 's|"v5.9.0"|"v5.8.0"|' "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:K3dVersion"* ]] || return 1
}

@test "check-facts --write: bumping the spec stamps EVERY consumer, then --check passes (#435)" {
  _set_spec K3D_VERSION v9.9.9
  run _facts --write
  [ "$status" -eq 0 ] || return 1
  grep -q 'K3D_VERSION="${K3D_VERSION:-v9.9.9}"' "$REPO/scripts/lib/common.sh"          # bash stamped
  grep -q 'else { "v9.9.9" }' "$REPO/scripts/install-k8s.ps1"                            # PowerShell stamped
  run _facts --check                                                                     # now consistent
  [ "$status" -eq 0 ] || return 1
}

@test "check-facts --write: HELM + K8S bumps stamp their consumers (#435)" {
  _set_spec HELM_VERSION v5.0.0
  _set_spec K8S_VERSION v1.30.0-k3s1
  _facts --write
  grep -q 'HELM_VERSION="${HELM_VERSION:-v5.0.0}"' "$REPO/scripts/lib/common.sh"
  grep -q 'else { "v5.0.0" }' "$REPO/scripts/install-k8s.ps1"
  grep -q 'K8S_VERSION="${K8S_VERSION:-v1.30.0-k3s1}"' "$REPO/scripts/lib/common.sh"
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts --check: READY_TIMEOUT (a real timeout budget) drift in ps1 -> RED (#435)" {
  local tmp; tmp="$(mktemp)"
  sed 's|"300"|"600"|' "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:ReadyTimeout"* ]] || return 1
}

@test "check-facts --write: bumping the READY_TIMEOUT budget stamps bash + PowerShell (#435)" {
  _set_spec READY_TIMEOUT 600
  _facts --write
  grep -q 'READY_TIMEOUT="${READY_TIMEOUT:-600}"' "$REPO/scripts/lib/summary.sh"   # bash consumer
  grep -q 'else { "600" }' "$REPO/scripts/install-k8s.ps1"                          # PowerShell consumer
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts: a missing pattern (consumer refactored away) fails closed, not silently green (#435)" {
  echo "# no k3d pin here anymore" > "$REPO/scripts/lib/common.sh"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no pinned value found"* ]] || return 1
}

@test "check-facts: an unknown mode is rejected (#435)" {
  run _facts --bogus
  [ "$status" -eq 2 ] || return 1
}
