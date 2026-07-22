#!/usr/bin/env bats
# Tests for scripts/lib/probe.sh — RFC 0001 host capability/privilege detection.
#
# Load-bearing properties:
#   • probes are READ-ONLY — the default path never pulls an image / mutates.
#   • classify picks the LOWEST workable tier; a usable runtime always wins (T0).
#   • a rootless-capable kernel ⇒ Tier 1 — we never fail a host for "can't modprobe".
#   • privilege posture cleanly separates root / sudo_nopw / sudo_pw / no_sudo.
#
# Same macOS bash-3.2 blindspot as the other suites: assertions go through the
# grep-backed assert_has / refute_has helpers so a false check fails loudly.
load test_helper

assert_has() {   # needle haystack
  printf '%s\n' "$2" | grep -qF -- "$1" && return 0
  printf 'ASSERT FAIL: expected to find >>%s<<\n--- in ---\n%s\n' "$1" "$2" >&2
  return 1
}
refute_has() {   # needle haystack
  if printf '%s\n' "$2" | grep -qF -- "$1"; then
    printf 'REFUTE FAIL: did NOT expect >>%s<<\n--- in ---\n%s\n' "$1" "$2" >&2
    return 1
  fi
  return 0
}

setup() {
  load_lib probe.sh
  MOCK_CALLS="$(mktemp)"
  unset INSTALL_TIER INSTALL_TIER_REASON \
        PROBE_RUNTIME_USABLE PROBE_PRIVILEGE PROBE_CGROUP2 PROBE_USERNS
  TB_PROBE_VERIFY=0
}

# ── _classify_from_probes: the tier truth table (pure) ───────────────────────

@test "classify: usable runtime => Tier 0" {
  OS=Linux; PROBE_RUNTIME_USABLE=1; PROBE_CGROUP2=0; PROBE_USERNS=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 0 ]
  [ "$INSTALL_TIER_REASON" = runtime-usable ]
}

@test "classify: runtime wins even on a non-rootless kernel" {
  OS=Linux; PROBE_RUNTIME_USABLE=1; PROBE_CGROUP2=0; PROBE_USERNS=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 0 ]
}

@test "classify: Linux, no runtime, rootless-capable => Tier 1" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=1
  _classify_from_probes
  [ "$INSTALL_TIER" = 1 ]
  [ "$INSTALL_TIER_REASON" = rootless-capable ]
}

@test "classify: Linux, userns disabled => Tier 2 (no-userns)" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 2 ]
  [ "$INSTALL_TIER_REASON" = no-userns ]
}

@test "classify: Linux, no cgroup v2 => Tier 2 (no-cgroup2)" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=0; PROBE_USERNS=1
  _classify_from_probes
  [ "$INSTALL_TIER" = 2 ]
  [ "$INSTALL_TIER_REASON" = no-cgroup2 ]
}

@test "classify: non-Linux, no runtime => Tier 2 (needs-docker-desktop)" {
  OS=Darwin; PROBE_RUNTIME_USABLE=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 2 ]
  [ "$INSTALL_TIER_REASON" = needs-docker-desktop ]
}

# ── _probe_privilege: the four postures ──────────────────────────────────────

@test "privilege: uid 0 => root" {
  id() { echo 0; }
  run _probe_privilege
  [ "$output" = root ]
}

@test "privilege: not root, sudo absent => no_sudo" {
  id() { echo 1000; }
  has() { [ "$1" = sudo ] && return 1; command -v "$1" >/dev/null 2>&1; }
  run _probe_privilege
  [ "$output" = no_sudo ]
}

@test "privilege: not root, passwordless sudo => sudo_nopw" {
  id() { echo 1000; }
  has() { return 0; }
  sudo() { return 0; }
  run _probe_privilege
  [ "$output" = sudo_nopw ]
}

@test "privilege: not root, sudo needs a password => sudo_pw" {
  id() { echo 1000; }
  has() { return 0; }
  sudo() { return 1; }
  run _probe_privilege
  [ "$output" = sudo_pw ]
}

# ── read-only guarantee ───────────────────────────────────────────────────────

@test "run_host_probes: read-only — no image pull on the default path" {
  OS=Linux; TB_PROBE_VERIFY=0
  docker() { record "docker $*"; case "$1" in info) return 0 ;; version) echo "27.0" ;; *) return 0 ;; esac; }
  id() { echo 1000; }
  has() { case "$1" in docker) return 0 ;; sudo) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  run_host_probes
  refute_has "docker run"  "$(mock_calls)"
  refute_has "docker pull" "$(mock_calls)"
  [ "$INSTALL_TIER" = 0 ]          # docker info OK => Tier 0
}

@test "verify probe pulls only when --verify is set" {
  has() { return 0; }
  docker() { record "docker $*"; return 0; }
  TB_PROBE_VERIFY=0
  _probe_verify_runtime
  refute_has "docker run" "$(mock_calls)"
  TB_PROBE_VERIFY=1
  _probe_verify_runtime
  assert_has "docker run" "$(mock_calls)"
}

# ── render_host_audit: the panel ──────────────────────────────────────────────

@test "audit: Tier 0 panel names zero root" {
  PROBE_RUNTIME_USABLE=1; PROBE_PRIVILEGE=sudo_pw
  INSTALL_TIER=0; INSTALL_TIER_REASON=runtime-usable
  docker() { echo "27.0"; }        # docker version --format
  run render_host_audit
  assert_has "Host check" "$output"
  assert_has "Tier 0" "$output"
}

@test "audit: Tier 1 panel shows the kernel row + rootless" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=1
  PROBE_PRIVILEGE=no_sudo; INSTALL_TIER=1; INSTALL_TIER_REASON=rootless-capable
  run render_host_audit
  assert_has "cgroup v2" "$output"
  assert_has "Tier 1" "$output"
  assert_has "rootless" "$output"
}

@test "audit: Tier 2 no-userns names the disabled namespaces" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=0
  PROBE_PRIVILEGE=no_sudo; INSTALL_TIER=2; INSTALL_TIER_REASON=no-userns
  run render_host_audit
  assert_has "Tier 2" "$output"
  assert_has "user namespaces" "$output"
}
