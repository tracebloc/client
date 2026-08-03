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
  [ "$status" -eq 0 ] || return 1
}

# ── _macos_require_admin (no-admin named remedy) ─────────────────────────────
@test "_macos_require_admin: admin passes through silently (#430)" {
  TB_MACOS_ADMIN_GROUPS="staff admin"
  run _macos_require_admin
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1   # no scary output for a normal admin
}

@test "_macos_require_admin: no-admin Mac -> hard fail with an ACCURATE remedy, not a generic sudo error (#430)" {
  TB_MACOS_ADMIN_GROUPS="staff everyone"   # not an admin
  run _macos_require_admin
  [ "$status" -ne 0 ] || return 1   # error() exits — fails fast up front
  [[ "$output" == *"isn't an administrator"* ]] || return 1
  [[ "$output" == *"administrator rights"* ]] || return 1   # the remedy that actually unblocks it
  [[ "$output" == *"admin account"* ]] || return 1   # …or install from an admin account
  [[ "$output" != *"prepare-host"* ]] || return 1   # NO macOS prepare-host exists (it errors on Darwin) (#430 Bugbot)
  [[ "$output" != *"grant this account access"* ]] || return 1   # not the re-run-as-non-admin loop (#430 Bugbot)
  [[ "$output" != *"sudo authentication failed"* ]] || return 1   # NOT the old generic message
}

# ── _install_macos_autostart (LaunchAgent) ───────────────────────────────────
@test "_install_macos_autostart: GUI Mac -> LaunchAgent opens Docker at login, RunAtLoad, TB_MACOS_AUTOSTART=1 (#430)" {
  TB_LAUNCHAGENTS_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  _has_gui_session() { return 0; }
  TB_MACOS_AUTOSTART=0
  _install_macos_autostart
  [ "$TB_MACOS_AUTOSTART" = "1" ] || return 1
  local plist="$TB_LAUNCHAGENTS_DIR/io.tracebloc.runtime.plist"
  [ -f "$plist" ] || return 1
  grep -q '<key>RunAtLoad</key><true/>' "$plist"
  grep -q '<string>/usr/bin/open</string>' "$plist"
  grep -q '<string>-a</string>' "$plist"
  grep -q '<string>Docker</string>' "$plist"
  grep -q 'Library/Logs/tracebloc-autostart.log' "$plist"   # per-user log, not shared /tmp (#430 Bugbot)
  ! grep -q '/tmp/tracebloc-autostart.log' "$plist" || return 1
  run mock_calls
  [[ "$output" == *"launchctl"* ]] || return 1   # registered for this session too
}

@test "_install_macos_autostart: headless Mac -> resilient LaunchDAEMON runs 'colima start' at BOOT (not a login-only agent) (#430 Bugbot)" {
  # A LaunchAgent only loads in a GUI/Aqua login session, which a headless Mac never has,
  # so headless reboot recovery MUST be a system LaunchDaemon that runs at boot.
  TB_LAUNCHDAEMONS_DIR="$BATS_TEST_TMPDIR/LaunchDaemons"
  HOME="$BATS_TEST_TMPDIR/home"             # daemon log dir lands under a temp home
  mkdir -p "$BATS_TEST_TMPDIR/bin"; printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/bin/colima"
  chmod +x "$BATS_TEST_TMPDIR/bin/colima"; PATH="$BATS_TEST_TMPDIR/bin:$PATH"   # colima IS the runtime
  _has_gui_session() { return 1; }
  sudo() { record "sudo $*"; "$@"; }        # passthrough so tee/mkdir really write
  _install_macos_autostart
  local plist="$TB_LAUNCHDAEMONS_DIR/io.tracebloc.runtime.plist"
  [ -f "$plist" ] || return 1
  [ -d "$HOME/Library/Logs" ] || return 1   # log dir created, else launchd EX_CONFIG (#430 Bugbot)
  grep -q '<string>/bin/bash</string>' "$plist"        # resilient wrapper, not a bare oneshot (#430 Bugbot)
  grep -q 'colima start' "$plist"
  grep -q 'colima stop --force' "$plist"                # retry FORCE-stops to clear stale VZ state (#430 Bugbot)
  grep -q '<key>RunAtLoad</key><true/>' "$plist"
  grep -q '<key>UserName</key>' "$plist"                # runs as the install user, at boot
  grep -q '<key>EnvironmentVariables</key>' "$plist"    # HOME/PATH for colima under launchd
  grep -q 'Library/Logs/tracebloc-autostart.log' "$plist"
  ! grep -q '/tmp/tracebloc-autostart.log' "$plist" || return 1
  run mock_calls
  [[ "$output" == *"sudo launchctl"* ]] || return 1   # registered in the SYSTEM domain
}

@test "_install_macos_autostart: headless but colima NOT installed -> skip honestly, no bogus daemon, flag unset (#430 Bugbot)" {
  # install_docker_desktop only installs colima when Docker was down; if Docker is already
  # up by other means colima may be absent, so we must NOT write a colima daemon or promise
  # auto-restart.
  TB_LAUNCHDAEMONS_DIR="$BATS_TEST_TMPDIR/LaunchDaemons"
  _has_gui_session() { return 1; }
  command() { if [ "$2" = colima ]; then return 1; fi; builtin command "$@"; }   # colima absent
  sudo() { record "sudo $*"; "$@"; }
  TB_MACOS_AUTOSTART=0
  run _install_macos_autostart
  [ "$status" -ne 0 ] || return 1   # best-effort skip (caller's || true)
  [[ "$output" == *"isn't installed"* ]] || return 1
  [ ! -e "$TB_LAUNCHDAEMONS_DIR/io.tracebloc.runtime.plist" ] || return 1   # no bogus daemon
  command() { if [ "$2" = colima ]; then return 1; fi; builtin command "$@"; }
  _has_gui_session() { return 1; }; TB_MACOS_AUTOSTART=0
  _install_macos_autostart || true
  [ "${TB_MACOS_AUTOSTART:-0}" = "0" ] || return 1   # summary won't falsely promise restart
}

@test "_install_macos_autostart: TRACEBLOC_NO_AUTOSTART -> skipped, nothing written, flag unset (#430 Bugbot)" {
  export TRACEBLOC_NO_AUTOSTART=1
  TB_LAUNCHAGENTS_DIR="$BATS_TEST_TMPDIR/LaunchAgents"
  TB_LAUNCHDAEMONS_DIR="$BATS_TEST_TMPDIR/LaunchDaemons"
  _has_gui_session() { return 0; }
  TB_MACOS_AUTOSTART=0
  run _install_macos_autostart
  [ "$status" -eq 0 ] || return 1   # honored, no error
  [ ! -e "$TB_LAUNCHAGENTS_DIR/io.tracebloc.runtime.plist" ] || return 1
  # flag stays unset -> the summary won't falsely promise auto-restart
  _has_gui_session() { return 0; }; TB_MACOS_AUTOSTART=0
  _install_macos_autostart
  [ "${TB_MACOS_AUTOSTART:-0}" = "0" ] || return 1
  unset TRACEBLOC_NO_AUTOSTART
}

@test "_install_macos_autostart: unwritable LaunchAgents dir -> best-effort warn, no crash, flag unset (#430)" {
  TB_LAUNCHAGENTS_DIR="/dev/null/cannot-mkdir-here"   # mkdir -p must fail
  _has_gui_session() { return 0; }
  TB_MACOS_AUTOSTART=0
  run _install_macos_autostart
  [ "$status" -ne 0 ] || return 1   # returns 1 (best-effort), never aborts the caller
  [[ "$output" == *"skipping login autostart"* ]] || return 1
  # the flag stays unset so the summary is honest about the reboot story
  _has_gui_session() { return 0; }; TB_MACOS_AUTOSTART=0
  _install_macos_autostart || true
  [ "${TB_MACOS_AUTOSTART:-0}" = "0" ] || return 1
}

# ── _reboot_note reflects the configured autostart ───────────────────────────
@test "install_macos: a failing autostart does NOT abort an otherwise-complete install (best-effort) (#430 Bugbot)" {
  # All prior steps succeed; autostart fails (mkdir/write). Under set -e the bare call
  # would have aborted the whole install after Docker + tools were already in — `|| true`
  # must keep it best-effort.
  _macos_require_admin()     { :; }
  preflight_sudo()           { :; }
  install_homebrew()         { :; }
  install_docker_desktop()   { :; }
  assert_amd64_emulation()   { :; }   # present once #433 merged; harmless no-op here
  install_macos_cli_tools()  { :; }
  _install_macos_autostart() { return 1; }   # simulate a LaunchAgents write failure
  run bash -c 'set -e; source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/setup-macos.sh"
    _macos_require_admin(){ :; }; preflight_sudo(){ :; }; install_homebrew(){ :; }
    install_docker_desktop(){ :; }; assert_amd64_emulation(){ :; }; install_macos_cli_tools(){ :; }
    _install_macos_autostart(){ return 1; }
    install_macos'
  [ "$status" -eq 0 ] || return 1   # install completes despite the autostart failure
}

@test "_reboot_note: macOS + autostart configured -> promises automatic restart (#430)" {
  OS=Darwin; TB_MACOS_AUTOSTART=1
  run _reboot_note
  [[ "$output" == *"restarts automatically"* ]] || return 1
  [[ "$output" != *"open Docker Desktop"* ]] || return 1
}

@test "_reboot_note: macOS without autostart -> unchanged 'open Docker Desktop' line (golden-safe) (#430)" {
  OS=Darwin; TB_MACOS_AUTOSTART=0
  run _reboot_note
  [[ "$output" == *"open Docker Desktop to bring tracebloc back"* ]] || return 1
}
