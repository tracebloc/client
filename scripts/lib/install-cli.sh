#!/usr/bin/env bash
# =============================================================================
#  install-cli.sh — Install the tracebloc CLI (Step 5)
#
#  Installs the `tracebloc` command-line tool so the user can push datasets to
#  the client they just set up:
#
#      tracebloc data ingest ./data
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

# _cli_at_system_dir PATH → true if the CLI lives in a SYSTEM location that's
# unconditionally on the user's shell PATH (so the summary CTA may say "run it
# now"); false for a $HOME bin (~/.local/bin, ~/bin) or an empty path — those may
# be on THIS installer's PATH only via the ~/.local/bin prepend or a just-edited
# rc, which the shell the user returns to hasn't read (Bugbot #371).
_cli_at_system_dir() {
  case "${1:-}" in
    "" | "${HOME%/}"/*) return 1 ;;
    *) return 0 ;;
  esac
}

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
# _cli_version_short prints the bare semver from `tracebloc version`
# ("tracebloc 0.9.3 (…)" → "0.9.3"). Cosmetic only — empty if the CLI isn't
# runnable or the format changes, so callers guard with ${ver:+…}.
_cli_version_short() {
  tracebloc version 2>/dev/null | head -1 | awk '{print $2}' || true
}

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
    # data ingest ./data" next step lives in the summary's "What to do next".
    # A fresh terminal WILL resolve tracebloc (that's this whole branch). The
    # summary CTA uses this to pick "open a new terminal" (case A) over the
    # PATH-fix guidance it must give when even a new shell can't find it (case B,
    # the outer fall-through below) — Bugbot #371.
    TB_CLI_ON_FRESH_PATH=1
    local ver; ver="$(_cli_version_short)"
    # Prefer the short `tb` alias (the CLI installer symlinks it next to
    # `tracebloc`); fall back to `tracebloc` when that alias wasn't created — its
    # name was already taken, so the CLI's install.sh skipped it — so the copy
    # never points the user at a command that isn't there (Bugbot).
    local cli_cmd="tracebloc"; has tb && cli_cmd="tb"
    # Whether the summary's CTA + this step may say "run it NOW" vs "open a new
    # terminal" — gate on WHERE the CLI landed, not `has tracebloc` (this process's
    # PATH was mutated with ~/.local/bin by install.sh, so it resolves the CLI even
    # when the user's returning shell won't). Only a system dir is unconditionally
    # on that shell's PATH (Bugbot #371).
    if has tracebloc && _cli_at_system_dir "$(command -v tracebloc 2>/dev/null)"; then
      TB_CLI_USABLE_NOW=1
      # Usable right now AND in new terminals — the fully-clean verdict, collapsed
      # to ONE line (old→new when this was an update), so the step shows a single
      # ✔ instead of an already-present / re-running / installing / ready pileup.
      if [[ -n "${TB_CLI_OLD_VER:-}" && -n "$ver" && "${TB_CLI_OLD_VER}" != "$ver" ]]; then
        # Only claim an upgrade when we CONFIRMED a new version. If the post-install
        # `tracebloc version` probe came back empty ($ver=""), we can't tell whether
        # anything changed — fall through to the neutral "up to date" rather than a
        # bare "updated" with no version to back it up (Bugbot: false updated verdict).
        success "tracebloc CLI updated${ver:+ (v${TB_CLI_OLD_VER} → v${ver})} — run \`${cli_cmd}\` to use it"
      elif [[ -n "${TB_CLI_OLD_VER:-}" ]]; then
        success "tracebloc CLI up to date${ver:+ (v${ver})} — run \`${cli_cmd}\` to use it"
      else
        success "tracebloc CLI ready${ver:+ (v${ver})} — run \`${cli_cmd}\` to use it"
      fi
      return 0
    fi
    # Installed and persisted for NEW terminals (a fresh shell resolves it — that's
    # why we're on this branch), but NOT usable in the user's returning shell yet:
    # either it landed in ~/.local/bin (the login shell fixed its PATH before that
    # dir existed, #304) or it's otherwise off this shell's PATH. Say "open a new
    # terminal" — matching the summary CTA — instead of "run it now", which would
    # fail command-not-found. The earlier code printed the usable-now verdict here
    # unconditionally, contradicting the summary (Bugbot #371). Keep
    # TB_CLI_USABLE_NOW=0 so _cli_runnable_now (summary.sh) agrees.
    TB_CLI_USABLE_NOW=0
    local sh_name; sh_name="$(basename "${SHELL:-/bin/sh}")"
    success "tracebloc CLI installed${ver:+ (v$ver)} — open a new terminal to use \`${cli_cmd}\`."
    if [[ "$sh_name" == "fish" ]]; then
      hint "This shell won't see it yet — open a new terminal to use it."
    else
      local rc; rc="$(_cli_rc_for_shell || true)"
      hint "This shell won't see it yet — open a new terminal, or load it now:  source ${rc}"
    fi
    info "Then the 'tracebloc data ingest ./data' step below will work."
    return 0
  fi

  # Installed, but a fresh terminal won't find it (e.g. it landed in
  # ~/.local/bin, which isn't on PATH). Tell the user precisely how to fix it
  # for THEIR shell — not a generic "open a new terminal" that won't help.
  # Not usable now AND a new shell won't resolve it either (case B): the summary
  # CTA must point at the PATH fix below, NOT "open a new terminal" (Bugbot #371).
  TB_CLI_USABLE_NOW=0
  TB_CLI_ON_FRESH_PATH=0
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
  info "Then the 'tracebloc data ingest ./data' step below will work."
  return 0
}

install_tracebloc_cli() {
  # No step framing here: this is called from provision_client (Step 3) on the
  # browser-auth path and, non-fatally, on the dual-mode path — the caller owns
  # the step heading. (#838 reorder: the CLI installs BEFORE Helm now.)
  # Remember the version already installed (if any) so the final ✔ can show a
  # clean "vX → vY" update instead of an already-present / re-running / installing
  # pileup. Cosmetic — a failing `tracebloc version` just yields "" (guarded).
  TB_CLI_OLD_VER=""
  if has tracebloc; then
    TB_CLI_OLD_VER="$(_cli_version_short)"
  fi
  # Whether the CLI ends up runnable in THIS shell (not just a fresh terminal).
  # summary.sh reads it to keep its final CTA honest — "Run tracebloc" vs "Open a
  # new terminal, then run tracebloc" (B2). _verify_tracebloc_cli overrides this
  # per THIS run's outcome. The DEFAULT is seeded from the PRE-install state: a
  # tracebloc ALREADY on a SYSTEM PATH dir (a prior install) is resolvable in the
  # user's shell unconditionally, so if the CLI step is later skipped or fails
  # (download/installer/temp-dir miss → early return, _verify never runs), the
  # summary must still say "Run" — not send a user with a working system tracebloc
  # to a new terminal (Bugbot #371). Gate on _cli_at_system_dir, NOT bare `has`:
  # install.sh prepends ~/.local/bin to THIS process, which would false-positive a
  # ~/.local/bin install the returning shell can't yet see.
  # shellcheck disable=SC2034  # consumed cross-file by summary.sh (_cli_runnable_now)
  if has tracebloc && _cli_at_system_dir "$(command -v tracebloc 2>/dev/null)"; then
    TB_CLI_USABLE_NOW=1
  else
    TB_CLI_USABLE_NOW=0
  fi

  local installer
  installer="$(mktemp)" || { warn "Couldn't install the tracebloc CLI (no temp dir) — your client is set up fine."; return 0; }

  # 1) Download the released installer. A failure here is a download problem,
  #    distinct from an install problem below.
  # --connect-timeout/--max-time so a stalled CDN turns into a clean "install later"
  # failure below instead of hanging the CLI-install step (this call isn't retry-
  # wrapped, and a hang is not a failure the graceful fallback would otherwise catch).
  if ! curl -fsSL "$CURL_SECURE" --connect-timeout 30 --max-time 120 "$TRACEBLOC_CLI_INSTALL_URL" -o "$installer" 2>>"${LOG_FILE:-/dev/null}"; then
    warn "Couldn't download the tracebloc CLI installer — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
    rm -f "$installer"
    return 0
  fi

  # 2) Run it behind a transient spinner (output → install log to keep the screen
  #    clean). Drive `spin` DIRECTLY rather than `spin_cmd`: this step is NON-FATAL
  #    (the client is already connected), but spin_cmd prints a hard red "✖ …" plus
  #    a 10-line log dump on failure — which would make a recoverable CLI hiccup
  #    look like a hard failure and reintroduce exactly the noisy output this step
  #    avoids. We surface the failure softly below instead. The CLI installer
  #    verifies SHA256 + cosign and falls back to ~/.local/bin (printing PATH
  #    guidance) when /usr/local/bin isn't writable.
  sh "$installer" >> "${LOG_FILE:-/dev/null}" 2>&1 &
  if spin "$!" "Installing the tracebloc CLI…"; then
    # Self-verify usability from a FRESH terminal and print the single ✔ line
    # (or a shell-correct PATH fix). Non-fatal — always returns 0.
    _verify_tracebloc_cli
  else
    warn "Couldn't install the tracebloc CLI automatically — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
  fi

  rm -f "$installer"
  return 0
}
