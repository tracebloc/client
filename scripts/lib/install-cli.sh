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

# Where the CLI's own installer drops the binary when /usr/local/bin isn't
# writable (see cli's install.sh) — the dir we tell the user to put on PATH.
TRACEBLOC_CLI_FALLBACK_BIN="${HOME}/.local/bin"

# Which rc file a *fresh* interactive shell of the user's $SHELL actually reads,
# so the PATH fix we print sources the right file. Mirrors how the cli's
# install.sh routes guidance, but resolved per-shell here:
#   zsh           → ~/.zshrc
#   bash + Linux  → ~/.bashrc      (a fresh non-login bash reads ~/.bashrc,
#                                    NOT ~/.profile — this is the failure mode)
#   bash + macOS  → ~/.bash_profile
#   fish          → ~/.config/fish/config.fish
#   anything else → ~/.profile     (POSIX sh fallback)
_cli_rc_for_shell() {
  local sh_name; sh_name="$(basename "${SHELL:-/bin/sh}")"
  case "$sh_name" in
    zsh)  echo "${HOME}/.zshrc" ;;
    bash)
      if [[ "${OS:-$(uname -s)}" == "Darwin" ]]; then
        echo "${HOME}/.bash_profile"
      else
        echo "${HOME}/.bashrc"
      fi
      ;;
    fish) echo "${HOME}/.config/fish/config.fish" ;;
    *)    echo "${HOME}/.profile" ;;
  esac
}

# The shell-correct line a fish user must add differs (no POSIX `export`).
_cli_path_export_line() {
  local sh_name; sh_name="$(basename "${SHELL:-/bin/sh}")"
  if [[ "$sh_name" == "fish" ]]; then
    echo "fish_add_path \"${TRACEBLOC_CLI_FALLBACK_BIN}\""
  else
    echo "export PATH=\"${TRACEBLOC_CLI_FALLBACK_BIN}:\$PATH\""
  fi
}

# Does a *fresh* shell resolve `tracebloc` on its PATH? This is the real test
# the success message has, until now, only asserted by hope: a brand-new
# terminal must find the binary. We probe two ways because they read different
# startup files:
#   1. login shell    ("$SHELL" -lic)  → ~/.profile / ~/.zprofile / ~/.bash_profile
#   2. non-login shell ("$SHELL" -ic)  → ~/.bashrc / ~/.zshrc
# A pass requires BOTH (cli#61 was "works in my login shell, missing in a plain
# `bash` subshell"). Indirected into its own function so the bats suite can stub
# it without spawning real shells. Never fatal: returns non-zero on "not found".
_cli_on_fresh_path() {
  local shell_bin="${SHELL:-/bin/sh}"
  "$shell_bin" -lic 'command -v tracebloc' >/dev/null 2>&1 || return 1
  "$shell_bin" -ic  'command -v tracebloc' >/dev/null 2>&1 || return 1
  return 0
}

# Post-install self-verification (#738). Proves the CLI is actually usable from
# a fresh terminal and prints a VERIFIED next command — or, if a new shell would
# NOT find it, the EXACT shell-correct PATH fix instead of a vague "open a new
# terminal". ALWAYS returns 0: the client is connected by Step 5, so a CLI
# verification hiccup must never abort an otherwise-successful install.
_verify_tracebloc_cli() {
  if _cli_on_fresh_path; then
    # Usable from a new terminal. `tracebloc version` is the real proof; keep it
    # cosmetic (never let a failing version call or a SIGPIPE flip the outcome).
    # The canonical "tracebloc dataset push ./data" next step lives in the
    # summary's "What to do next" — don't duplicate it here; just confirm the
    # verdict so the summary's command is known-good.
    local ver; ver="$(tracebloc version 2>/dev/null | head -1 || true)"
    success "tracebloc CLI installed${ver:+ ($ver)} — verified on your PATH."
    return 0
  fi

  # Installed, but a fresh terminal won't find it (e.g. it landed in
  # ~/.local/bin, which isn't on PATH). Tell the user precisely how to fix it
  # for THEIR shell — not a generic "open a new terminal" that won't help.
  # `|| true` so a hiccup in rc-resolution can't trip the orchestrator's set -e.
  local rc; rc="$(_cli_rc_for_shell || true)"
  local export_line; export_line="$(_cli_path_export_line || true)"
  success "tracebloc CLI installed — one step to put it on your PATH in this terminal:"
  hint "  ${export_line}"
  hint "  source ${rc}"
  info "After that, the 'tracebloc dataset push ./data' step below will work here."
  info "(New terminals pick it up automatically once ${rc} has the line above.)"
  return 0
}

install_tracebloc_cli() {
  step 5 5 "Install the tracebloc CLI"

  if has tracebloc; then
    # Version is cosmetic — never let a failing `tracebloc version` (or SIGPIPE
    # from `head` closing the pipe, under `set -o pipefail`) abort this step.
    # `local` masks the status and `|| true` keeps any captured value.
    local ver="$(tracebloc version 2>/dev/null | head -1 || true)"
    info "tracebloc CLI already present${ver:+ ($ver)} — re-running its installer to pick up the latest."
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
    # Self-verify usability from a FRESH terminal and print a verified next
    # command (or a shell-correct PATH fix). Non-fatal — always returns 0.
    _verify_tracebloc_cli
  else
    warn "Couldn't install the tracebloc CLI automatically — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
  fi

  rm -f "$installer"
  return 0
}
