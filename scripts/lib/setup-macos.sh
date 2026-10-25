#!/usr/bin/env bash
# =============================================================================
#  setup-macos.sh — macOS step b: the macOS node (mac-container.sh)
# -----------------------------------------------------------------------------
#  A Mac has one substrate: k3s in Apple's container runtime, unpacked into the
#  user's own folder (RFC-0175 D1, D6). This installer sets up no other runtime
#  on a Mac (slim client 4.1, client-dev#1948), so step b here is the macOS
#  node's, and this file keeps only what the node's path reads: the launchd plist
#  skeleton, and the Mac's answer to "can the amd64-only MySQL 5.7 engine run
#  here?".
# =============================================================================

# Emit a launchd plist to stdout: Label, RunAtLoad, ProgramArguments=$@, a per-user
# LOGPATH for std{out,err}, plus any raw EXTRA XML (e.g. the login item's
# EnvironmentVariables). The macOS node's login item writes its plist through it
# (mac-container.sh, _mac_ct_agent_plist). LOGPATH must be per-user (not a fixed
# /tmp path): with the installer's umask 077 a shared /tmp log is created 0600 by the
# first account and a second account's job then can't open it (EX_CONFIG → the job
# never starts), and /tmp is symlink-plantable on a shared Mac (#430 Bugbot).
_emit_launch_plist() {
  local label="$1" extra="$2" logpath="$3"; shift 3
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0">'
  printf '%s\n' '<dict>'
  printf '  <key>Label</key><string>%s</string>\n' "$label"
  printf '%s\n' '  <key>ProgramArguments</key>'
  printf '%s\n' '  <array>'
  local _a
  for _a in "$@"; do printf '    <string>%s</string>\n' "$_a"; done
  printf '%s\n' '  </array>'
  printf '%s\n' '  <key>RunAtLoad</key><true/>'
  [[ -n "$extra" ]] && printf '%s\n' "$extra"
  printf '  <key>StandardOutPath</key><string>%s</string>\n' "$logpath"
  printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$logpath"
  printf '%s\n' '</dict>'
  printf '%s\n' '</plist>'
}

# The macOS amd64-emulation refusal: the Rosetta remedy. Read by the late
# _assert_engine_runs_on_this_arch gate (install-client-helm.sh) on an Apple silicon
# Mac whose install resolved to the amd64-only MySQL 5.7 engine, so the refusal gives
# the Mac's fix, never the Linux binfmt one.
_macos_amd64_refusal() {
  warn "This Apple silicon Mac doesn't have Rosetta, and this install resolved to the amd64-only MySQL 5.7 engine — it would crash-loop, not fail here."
  hint "  Install Rosetta (softwareupdate --install-rosetta), then re-run: the macOS node runs amd64 images under it."
  hint "  (or set TRACEBLOC_ALLOW_ARM64=1 to proceed anyway — the images may crash.)"
  error "amd64 emulation unavailable — fix the above and re-run (this install needs the amd64-only MySQL 5.7 engine; a fresh install would use the native 8.4 engine instead)."
}

# Boolean: does the macOS node run amd64 images? It does exactly when it was created
# with --rosetta, which _mac_ct_node_argv adds when _mac_ct_rosetta_present holds, and
# a run whose argv differs from the node's recreates it (mac-container.sh, part 3). So
# this asks that one function, not a copy of it. A build without mac-container.sh
# cannot tell, and fails closed.
_macos_amd64_emulation_ok() {
  declare -F _mac_ct_rosetta_present >/dev/null 2>&1 && _mac_ct_rosetta_present
}

install_macos() {
  # The macOS node (RFC-0175 D6) is step b on every Mac: the node runs in Apple's VM
  # from the user's own folder, so it installs no other runtime and needs no
  # administrator (mac-container.sh). tb_substrate_resolve gives a Mac no
  # other substrate (_tb_substrate_fresh_here), and main() refuses a TRACEBLOC_SUBSTRATE
  # naming a retired one before this step, so anything else here is a defect, refused
  # rather than set up.
  local left
  left="$(_tb_substrate_fresh_here)" || left=""
  [[ -n "$left" && "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "$left" ]] \
    || error "This installer sets up only ${left:-one runtime} on a Mac, and this run resolved '${TRACEBLOC_SUBSTRATE_RESOLVED:-}'. Unset TRACEBLOC_SUBSTRATE, then re-run."
  declare -F _mac_ct_install_macos >/dev/null 2>&1 \
    || error "This installer build can't set up the macOS node (mac-container.sh is missing: stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
  _mac_ct_install_macos
}
