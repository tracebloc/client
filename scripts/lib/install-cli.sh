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
    # A brand-new terminal resolves tracebloc — the rc PATH edit persisted. But
    # `_cli_on_fresh_path` spawns FRESH shells; the caller's CURRENT shell may
    # predate that edit. When the binary lands in ~/.local/bin, the shell that
    # launched this installer fixed its PATH at login (before the dir existed)
    # and won't see it until it re-reads its rc — so the very next `tracebloc …`
    # the user types HERE fails with command-not-found even though a new terminal
    # works (#304). Only claim "verified on your PATH" when THIS shell resolves it
    # too; otherwise be honest and say how to use it now.
    # `tracebloc version` is the real proof; keep it cosmetic (never let a failing
    # version call or a SIGPIPE flip the outcome). The canonical "tracebloc
    # dataset push ./data" next step lives in the summary's "What to do next".
    local ver; ver="$(tracebloc version 2>/dev/null | head -1 || true)"
    if has tracebloc; then
      # Usable right now AND in new terminals — the fully-clean verdict.
      success "tracebloc CLI installed${ver:+ ($ver)} — verified on your PATH."
      return 0
    fi
    # Persisted for new terminals, but not yet on THIS shell's PATH. The rc
    # already carries the PATH line (that's why a fresh shell finds it), so the
    # user just needs a new terminal — or to load the rc into this one. Don't
    # re-append it; don't over-claim "verified on your PATH" for a shell it isn't.
    local sh_name; sh_name="$(basename "${SHELL:-/bin/sh}")"
    success "tracebloc CLI installed${ver:+ ($ver)} — verified for new terminals."
    if [[ "$sh_name" == "fish" ]]; then
      hint "This shell won't see it yet — open a new terminal to use it."
    else
      local rc; rc="$(_cli_rc_for_shell || true)"
      hint "This shell won't see it yet — open a new terminal, or load it now:  source ${rc}"
    fi
    info "Then the 'tracebloc dataset push ./data' step below will work."
    return 0
  fi

  # Installed, but a fresh terminal won't find it (e.g. it landed in
  # ~/.local/bin, which isn't on PATH). Tell the user precisely how to fix it
  # for THEIR shell — not a generic "open a new terminal" that won't help.
  # `|| true` so a hiccup in rc-resolution can't trip the orchestrator's set -e.
  local rc; rc="$(_cli_rc_for_shell || true)"
  local export_line; export_line="$(_cli_path_export_line || true)"
  local sh_name; sh_name="$(basename "${SHELL:-/bin/sh}")"
  success "tracebloc CLI installed — put it on your PATH:"
  if [[ "$sh_name" == "fish" ]]; then
    # fish_add_path persists (a universal var) AND applies to this shell — no
    # `source` needed, unlike a POSIX rc edit.
    hint "  ${export_line}"
  else
    # Append the line to the rc, then load it: fixes THIS terminal and every
    # new one in a single copy-pasteable step (the old code printed a bare
    # `export` that fixed only this shell, then `source`d an rc that didn't
    # yet contain the line — so nothing persisted).
    hint "  echo '${export_line}' >> ${rc}"
    hint "  source ${rc}"
  fi
  info "Then the 'tracebloc dataset push ./data' step below will work."
  return 0
}

install_tracebloc_cli() {
  # No step framing here: this is called from provision_client (Step 3) on the
  # browser-auth path and, non-fatally, on the dual-mode path — the caller owns
  # the step heading. (#838 reorder: the CLI installs BEFORE Helm now.)
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
