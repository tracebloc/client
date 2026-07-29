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
  # _probe_runtime_usable now bounds `docker info` with timeout/gtimeout, but in
  # tests `docker` is a shell-function mock that the EXTERNAL timeout can't see.
  # Shadow timeout/gtimeout with a passthrough that drops the duration and runs
  # the rest (so the mocked docker is still invoked). Individual tests that assert
  # on the bound override these.
  timeout()  { shift; "$@"; }
  gtimeout() { shift; "$@"; }
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

@test "classify: macOS, no runtime => Tier 2 (needs-docker-desktop)" {
  OS=Darwin; PROBE_RUNTIME_USABLE=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 2 ]
  [ "$INSTALL_TIER_REASON" = needs-docker-desktop ]
}

@test "classify: other non-Linux (Git Bash/MINGW) => Tier 2 (unsupported-os), not Docker Desktop (#370)" {
  OS="MINGW64_NT-10.0"; PROBE_RUNTIME_USABLE=0
  _classify_from_probes
  [ "$INSTALL_TIER" = 2 ]
  [ "$INSTALL_TIER_REASON" = unsupported-os ]
}

# ── _probe_privilege: the four postures ──────────────────────────────────────

@test "privilege: uid 0 => root" {
  id() { echo 0; }
  run _probe_privilege
  [ "$output" = root ]
}

@test "privilege: not root, sudo absent => no_sudo" {
  id() { echo 1000; }
  # No real sudo binary — even if the A2 sudo() shadow is defined (Bugbot #372).
  _have_sudo_bin() { return 1; }
  run _probe_privilege
  [ "$output" = no_sudo ]
}

@test "privilege: not root, passwordless sudo => sudo_nopw" {
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { return 0; }
  run _probe_privilege
  [ "$output" = sudo_nopw ]
}

@test "privilege: not root, sudo needs a password => sudo_pw" {
  id() { echo 1000; }
  _have_sudo_bin() { return 0; }
  _real_sudo() { return 1; }
  run _probe_privilege
  [ "$output" = sudo_pw ]
}

# ── _probe_subid_ranges / _probe_uidmap_helpers (rootless prereqs, #1220) ─────
# _probe_subid_ranges keys off `id -un` (the user the rootless daemon runs as), so
# the mocks distinguish `id -un` (name) from `id -u` (numeric uid) (#458).

@test "subid: range present in BOTH files (by name) => present" {
  USER=testuser; id() { [ "$1" = "-un" ] && echo testuser || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'testuser:100000:65536\n' >"$TB_SUBUID_FILE"
  printf 'testuser:100000:65536\n' >"$TB_SUBGID_FILE"
  _probe_subid_ranges
}

@test "subid: range keyed by numeric uid => present" {
  USER=testuser; id() { [ "$1" = "-un" ] && echo testuser || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf '1000:100000:65536\n' >"$TB_SUBUID_FILE"
  printf '1000:100000:65536\n' >"$TB_SUBGID_FILE"
  _probe_subid_ranges
}

@test "subid: present in subuid but MISSING from subgid => not present (both required)" {
  USER=testuser; id() { [ "$1" = "-un" ] && echo testuser || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'testuser:100000:65536\n' >"$TB_SUBUID_FILE"
  : >"$TB_SUBGID_FILE"
  run _probe_subid_ranges
  [ "$status" -ne 0 ]
}

@test "subid: both files empty => not present" {
  USER=testuser; id() { [ "$1" = "-un" ] && echo testuser || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  run _probe_subid_ranges
  [ "$status" -ne 0 ]
}

@test "subid: keyed off id -un not \$USER — su/cron divergence can't false-positive (#458)" {
  # daemon user (id -un) is 'bob'; login \$USER is 'alice'. A range for alice must
  # NOT read as present for bob, or the gate would skip and rootless die deep.
  USER=alice; id() { [ "$1" = "-un" ] && echo bob || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'alice:100000:65536\n' >"$TB_SUBUID_FILE"
  printf 'alice:100000:65536\n' >"$TB_SUBGID_FILE"
  run _probe_subid_ranges
  [ "$status" -ne 0 ]
}

@test "subid: a name that is a substring of another entry does NOT false-positive" {
  USER=test; id() { [ "$1" = "-un" ] && echo test || echo 4242; }   # entries are 'testuser'
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'testuser:100000:65536\n' >"$TB_SUBUID_FILE"
  printf 'testuser:100000:65536\n' >"$TB_SUBGID_FILE"
  run _probe_subid_ranges
  [ "$status" -ne 0 ]
}

# NOTE: these clobber PATH to $bin for a hermetic probe (hide any system newuidmap),
# but ONLY inside a subshell — setting PATH="$bin" in the test body also hides `rm`,
# which breaks bats-core's own per-test cleanup and fails the whole run even when
# every test passes (bats 1.10+; root cause of the #458 red bats). Functions defined
# in the body (getcap mock, has) are inherited by the subshell.
@test "uidmap: both helpers present AND setuid => satisfied" {
  bin="$(mktemp -d)"
  : >"$bin/newuidmap"; : >"$bin/newgidmap"
  chmod u+s "$bin/newuidmap" "$bin/newgidmap"
  ( PATH="$bin"; _probe_uidmap_helpers )
}

@test "uidmap: filecaps (no setuid bit) => satisfied — newuidmap:cap_setuid, newgidmap:cap_setgid (Arch shadow, #458)" {
  bin="$(mktemp -d)"
  : >"$bin/newuidmap"; : >"$bin/newgidmap"
  chmod +x "$bin/newuidmap" "$bin/newgidmap"       # NO setuid bit
  # Each helper carries its OWN capability: newuidmap → cap_setuid, newgidmap → cap_setgid.
  getcap() { case "$1" in *newgidmap) printf '%s cap_setgid=ep\n' "$1" ;; *) printf '%s cap_setuid=ep\n' "$1" ;; esac; }
  ( PATH="$bin"; _probe_uidmap_helpers )
}

@test "uidmap: newgidmap with only cap_setuid (wrong cap) => NOT satisfied (#458)" {
  bin="$(mktemp -d)"
  : >"$bin/newuidmap"; : >"$bin/newgidmap"
  chmod +x "$bin/newuidmap" "$bin/newgidmap"
  # Both report cap_setuid; newgidmap actually needs cap_setgid, so it must be rejected.
  getcap() { printf '%s cap_setuid=ep\n' "$1"; }
  ! ( PATH="$bin"; _probe_uidmap_helpers )
}

@test "uidmap: present with neither setuid bit nor cap_setuid => not satisfied" {
  bin="$(mktemp -d)"
  : >"$bin/newuidmap"; : >"$bin/newgidmap"
  chmod +x "$bin/newuidmap" "$bin/newgidmap"
  getcap() { printf '%s =\n' "$1"; }               # getcap present, no caps
  ! ( PATH="$bin"; _probe_uidmap_helpers )
}

@test "uidmap: one helper missing => not satisfied" {
  bin="$(mktemp -d)"
  : >"$bin/newuidmap"; chmod u+s "$bin/newuidmap"   # newgidmap absent
  ! ( PATH="$bin"; _probe_uidmap_helpers )
}

@test "subid probes: side-effect-free — fixtures unchanged after run_host_probes" {
  OS=Linux; USER=testuser; id() { [ "$1" = "-un" ] && echo testuser || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'testuser:100000:65536\n' >"$TB_SUBUID_FILE"
  printf 'testuser:100000:65536\n' >"$TB_SUBGID_FILE"
  before_u="$(cat "$TB_SUBUID_FILE")"; before_g="$(cat "$TB_SUBGID_FILE")"
  _probe_runtime_usable() { return 1; }
  _probe_cgroup_v2()      { return 0; }
  _probe_userns()         { return 0; }
  _probe_privilege()      { echo no_sudo; }
  _probe_uidmap_helpers() { return 0; }
  run_host_probes
  [ "$PROBE_SUBID" = 1 ]
  [ "$(cat "$TB_SUBUID_FILE")" = "$before_u" ]
  [ "$(cat "$TB_SUBGID_FILE")" = "$before_g" ]
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

# The default-path daemon check must be bounded so a wedged Docker can't hang a
# headless install (Bugbot r3655543152).
@test "_probe_runtime_usable: bounds 'docker info' with a timeout cap" {
  has() { case "$1" in docker|timeout) return 0 ;; *) return 1 ;; esac; }
  timeout() { record "timeout $*"; shift; "$@"; }
  docker()  { record "docker $*"; case "$1" in info) return 0 ;; *) return 0 ;; esac; }
  _probe_runtime_usable
  assert_has "timeout 5 docker info" "$(mock_calls)"   # 5s-bounded, not a bare call
}

@test "_probe_runtime_usable: no timeout/gtimeout binary -> falls back to bare docker info" {
  has() { case "$1" in docker) return 0 ;; timeout|gtimeout) return 1 ;; *) return 1 ;; esac; }
  docker() { record "docker $*"; return 0; }
  _probe_runtime_usable
  assert_has "docker info" "$(mock_calls)"
  refute_has "timeout" "$(mock_calls)"
}

@test "_probe_runtime_usable: docker info non-zero (wedged/timed out) -> not usable, never fatal" {
  has() { case "$1" in docker) return 0 ;; timeout|gtimeout) return 1 ;; *) return 1 ;; esac; }
  docker() { return 1; }              # daemon unreachable, or timeout killed it (124)
  run _probe_runtime_usable
  [ "$status" -ne 0 ]                 # "not usable" — no error thrown
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

@test "run_host_probes: --verify demotes a daemon that answers docker info but can't run a container (#370)" {
  OS=Linux; TB_PROBE_VERIFY=1
  docker() { case "$1" in info) return 0 ;; run) return 1 ;; version) echo "27.0" ;; *) return 0 ;; esac; }
  id() { echo 1000; }
  has() { case "$1" in docker) return 0 ;; sudo) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  run_host_probes
  [ "$PROBE_RUNTIME_USABLE" = 0 ]   # docker info OK but `docker run` failed => not usable
  [ "$INSTALL_TIER" != 0 ]          # so NOT Tier 0
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

@test "audit: Tier 1 panel shows the kernel row + the one-time admin note" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=1
  PROBE_PRIVILEGE=no_sudo; INSTALL_TIER=1; INSTALL_TIER_REASON=rootless-capable
  run render_host_audit
  assert_has "cgroup v2" "$output"
  assert_has "Tier 1" "$output"
  # Tier 1 still runs the privileged install path (install_linux) until rootless
  # Docker lands (#1177), so the audit must be honest about the one-time admin step.
  assert_has "one-time admin" "$output"
}

@test "audit: Tier 1 shows the rootless prerequisite rows (subid + uidmap)" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=1
  PROBE_SUBID=0; PROBE_UIDMAP=1
  PROBE_PRIVILEGE=no_sudo; INSTALL_TIER=1; INSTALL_TIER_REASON=rootless-capable
  run render_host_audit
  assert_has "Subordinate IDs" "$output"
  assert_has "no range for this user" "$output"          # PROBE_SUBID=0
  assert_has "newuidmap + newgidmap present" "$output"    # PROBE_UIDMAP=1
}

@test "audit: Tier 2 no-userns names the disabled namespaces" {
  OS=Linux; PROBE_RUNTIME_USABLE=0; PROBE_CGROUP2=1; PROBE_USERNS=0
  PROBE_PRIVILEGE=no_sudo; INSTALL_TIER=2; INSTALL_TIER_REASON=no-userns
  run render_host_audit
  assert_has "Tier 2" "$output"
  assert_has "user namespaces" "$output"
}
