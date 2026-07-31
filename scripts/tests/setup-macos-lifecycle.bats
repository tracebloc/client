#!/usr/bin/env bats
# macOS lifecycle (#430): login autostart so a rebooted Mac returns with zero action,
# a named IT-facing remedy on no-admin (managed) Macs instead of a generic sudo error,
# and the summary reboot line reflecting the configured autostart. Runs on Linux CI too
# — behaviour is driven by mocks/overrides, not the host. Separate file from
# setup-macos.bats / setup-macos-arch.bats to avoid a file-add clash across parallel PRs.
load test_helper

setup() {
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/summary.sh"     # _reboot_note
  LOG_FILE=/dev/null
  MOCK_CALLS="$(mktemp)"
  OS="Darwin"; ARCH="arm64"
  launchctl() { record "launchctl $*"; }
}

# ── _macos_user_is_admin ─────────────────────────────────────────────────────
@test "_macos_user_is_admin: admin group -> yes; standard account -> no (#430)" {
  TB_MACOS_ADMIN_GROUPS="staff admin everyone"; run _macos_user_is_admin; [ "$status" -eq 0 ]
  TB_MACOS_ADMIN_GROUPS="staff everyone";       run _macos_user_is_admin; [ "$status" -ne 0 ]
}

@test "_macos_user_is_admin: root -> yes (#430)" {
  id() { [ "$1" = "-u" ] && echo 0 || echo "root wheel"; }
  run _macos_user_is_admin
  [ "$status" -eq 0 ]
}

# ── _macos_require_admin (no-admin named remedy) ─────────────────────────────
@test "_macos_require_admin: admin passes through silently (#430)" {
  TB_MACOS_ADMIN_GROUPS="staff admin"
  run _macos_require_admin
  [ "$status" -eq 0 ]
  [ -z "$output" ]                         # no scary output for a normal admin
}

@test "_macos_require_admin: no-admin Mac -> hard fail with a named IT remedy, not a generic sudo error (#430)" {
  TB_MACOS_ADMIN_GROUPS="staff everyone"   # not an admin
  run _macos_require_admin
  [ "$status" -ne 0 ]                       # error() exits — fails fast up front
  [[ "$output" == *"isn't an administrator"* ]]
  [[ "$output" == *"IT/admin"* ]]
  [[ "$output" == *"Docker Desktop"* ]]
  [[ "$output" == *"prepare-host"* ]]      # names the macOS prepare-host analog
  [[ "$output" != *"sudo authentication failed"* ]]   # NOT the old generic message
}

# ── _install_macos_autostart (LaunchAgent) ───────────────────────────────────
@test "_install_macos_autostart: GUI Mac -> LaunchAgent opens Docker at login, RunAtLoad, TB_MACOS_AUTOSTART=1 (#430)" {
  TB_LAUNCHAGENTS_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  _has_gui_session() { return 0; }
  TB_MACOS_AUTOSTART=0
  _install_macos_autostart
  [ "$TB_MACOS_AUTOSTART" = "1" ]
  local plist="$TB_LAUNCHAGENTS_DIR/io.tracebloc.runtime.plist"
  [ -f "$plist" ]
  grep -q '<key>RunAtLoad</key><true/>' "$plist"
  grep -q '<string>/usr/bin/open</string>' "$plist"
  grep -q '<string>-a</string>' "$plist"
  grep -q '<string>Docker</string>' "$plist"
  run mock_calls
  [[ "$output" == *"launchctl"* ]]         # registered for this session too
}

@test "_install_macos_autostart: headless Mac -> LaunchAgent runs 'colima start' at login (#430)" {
  TB_LAUNCHAGENTS_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  _has_gui_session() { return 1; }
  _install_macos_autostart
  local plist="$TB_LAUNCHAGENTS_DIR/io.tracebloc.runtime.plist"
  [ -f "$plist" ]
  grep -q 'colima</string>' "$plist"       # …/colima
  grep -q '<string>start</string>' "$plist"
  grep -q '<key>RunAtLoad</key><true/>' "$plist"
}

@test "_install_macos_autostart: unwritable LaunchAgents dir -> best-effort warn, no crash, flag unset (#430)" {
  TB_LAUNCHAGENTS_DIR="/dev/null/cannot-mkdir-here"   # mkdir -p must fail
  _has_gui_session() { return 0; }
  TB_MACOS_AUTOSTART=0
  run _install_macos_autostart
  [ "$status" -ne 0 ]                       # returns 1 (best-effort), never aborts the caller
  [[ "$output" == *"skipping login autostart"* ]]
  # the flag stays unset so the summary is honest about the reboot story
  _has_gui_session() { return 0; }; TB_MACOS_AUTOSTART=0
  _install_macos_autostart || true
  [ "${TB_MACOS_AUTOSTART:-0}" = "0" ]
}

# ── _reboot_note reflects the configured autostart ───────────────────────────
@test "_reboot_note: macOS + autostart configured -> promises automatic restart (#430)" {
  OS=Darwin; TB_MACOS_AUTOSTART=1
  run _reboot_note
  [[ "$output" == *"restarts automatically"* ]]
  [[ "$output" != *"open Docker Desktop"* ]]
}

@test "_reboot_note: macOS without autostart -> unchanged 'open Docker Desktop' line (golden-safe) (#430)" {
  OS=Darwin; TB_MACOS_AUTOSTART=0
  run _reboot_note
  [[ "$output" == *"open Docker Desktop to bring tracebloc back"* ]]
}
