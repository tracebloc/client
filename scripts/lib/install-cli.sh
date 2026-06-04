#!/usr/bin/env bash
# =============================================================================
#  install-cli.sh — Install the tracebloc CLI (Step 5)
#
#  Installs the `tracebloc` command-line tool so the user can push datasets to
#  the client they just set up:
#
#      tracebloc dataset push ./data
#
#  It does NOT reimplement any install logic — it runs the CLI's own released
#  installer (github.com/tracebloc/cli), which downloads the right build for
#  this OS/arch and verifies it (SHA256 + cosign signature) before installing.
#  Keeping that logic in the cli repo means this stays correct as the CLI's
#  platform matrix / signing evolves.
#
#  NON-FATAL by design: this runs AFTER the client is already connected, so a
#  CLI-install hiccup must warn and move on — it must never turn a successful
#  "Connected to tracebloc" into a failed install. Every path returns 0, and
#  detection does NOT rely on the caller's `set -o pipefail` (we download to a
#  temp file and check each step explicitly rather than `curl | sh`).
# =============================================================================

TRACEBLOC_CLI_INSTALL_URL="https://github.com/tracebloc/cli/releases/latest/download/install.sh"

install_tracebloc_cli() {
  step 5 5 "Install the tracebloc CLI"

  if has tracebloc; then
    info "tracebloc CLI already present ($(tracebloc version 2>/dev/null | head -1)) — re-running its installer to pick up the latest."
  fi

  info "Installing the tracebloc CLI (dataset push / cluster info / dataset rm)…"

  local installer
  installer="$(mktemp)" || { warn "Couldn't install the tracebloc CLI (no temp dir) — your client is set up fine."; return 0; }

  # 1) Download the released installer. A failure here is a download problem,
  #    distinct from an install problem below.
  if ! curl -fsSL "$CURL_SECURE" "$TRACEBLOC_CLI_INSTALL_URL" -o "$installer" 2>>"${LOG_FILE:-/dev/null}"; then
    warn "Couldn't download the tracebloc CLI installer — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
    rm -f "$installer"
    return 0
  fi

  # 2) Run it. Output → install log to keep this screen clean. The CLI installer
  #    verifies SHA256 + cosign and falls back to ~/.local/bin (printing PATH
  #    guidance) when /usr/local/bin isn't writable.
  if sh "$installer" >> "${LOG_FILE:-/dev/null}" 2>&1; then
    if has tracebloc; then
      success "tracebloc CLI installed ($(tracebloc version 2>/dev/null | head -1))."
    else
      success "tracebloc CLI installed — open a new terminal so it's on your PATH."
    fi
  else
    warn "Couldn't install the tracebloc CLI automatically — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
  fi

  rm -f "$installer"
  return 0
}
