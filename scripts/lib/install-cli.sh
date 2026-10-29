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
#  After a connected install, setup_example_use_case has that CLI set up the
#  account's example use case (`tracebloc data ingest --example`), also non-fatal.
#
#  NON-FATAL by design: this runs AFTER the client is already connected, so a
#  CLI-install hiccup must warn and move on — it must never turn a successful
#  "Connected to tracebloc" into a failed install. Every path returns 0, and
#  detection does NOT rely on the caller's `set -o pipefail` (we download to a
#  temp file and check each step explicitly rather than `curl | sh`).
#  The one exit is require_tracebloc_cli_floor, run after it: a CLI left below
#  the platform's floor stops the install.
# =============================================================================

TRACEBLOC_CLI_INSTALL_URL="https://github.com/tracebloc/cli/releases/latest/download/install.sh"

# Where the CLI's own installer drops the binary when /usr/local/bin isn't
# writable (see cli's install.sh) — the dir we tell the user to put on PATH.
TRACEBLOC_CLI_FALLBACK_BIN="${HOME}/.local/bin"

# The absolute path of the CLI this run installed, as its installer reported it; empty
# until install_tracebloc_cli records one. Set here, not inherited: a path from the
# environment must not stand in for a binary this run did not install.
TRACEBLOC_CLI_BIN=""

# 1 once this run's device sign-in signed the CLI in (provision_client), so the CLI's
# account is the one that owns the client this run connects. Set here, not inherited:
# only this run's sign-in vouches for that (setup_example_use_case reads it).
TB_CLI_SIGNED_IN=""

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

# _cli_on_launch_path BIN -> 0 when BIN's directory was on the PATH of the shell
# that started the install (TRACEBLOC_LAUNCH_PATH, captured by install.sh / common.sh
# before either prepends anything). That shell is the one the user types the next
# command into, so a CLI in ~/.local/bin is usable there right away when the user's
# PATH already had ~/.local/bin -- the common case on a re-install. Without this,
# such a user was told "open a new terminal" while their shell already found the
# CLI (backend#5025 O-103). Conservative: an unset or empty TRACEBLOC_LAUNCH_PATH, or a BIN
# that is not an absolute path, is "no". A bootstrap older than common.sh has already
# prepended ~/.local/bin by the time common.sh captures the PATH, so common.sh drops
# that leading entry from the capture instead of trusting it.
_cli_on_launch_path() {
  local bin="${1:-}" dir
  case "$bin" in /*) ;; *) return 1 ;; esac
  [[ -n "${TRACEBLOC_LAUNCH_PATH:-}" ]] || return 1
  dir="${bin%/*}"
  case ":${TRACEBLOC_LAUNCH_PATH}:" in *":${dir}:"* | *":${dir}/:"*) return 0 ;; esac
  return 1
}

# _cli_usable_in_launch_shell BIN -> 0 when the user's own shell resolves BIN now:
# it sits in a system dir (always on that PATH) or in a directory that was already
# on it (_cli_on_launch_path). The one gate behind TB_CLI_USABLE_NOW.
_cli_usable_in_launch_shell() {
  _cli_at_system_dir "${1:-}" || _cli_on_launch_path "${1:-}"
}

# _cli_reported_path OUTFILE -> the binary the CLI's own installer says it
# installed: the path on the last "tracebloc CLI installed: <path>" line of its
# captured output (cli's install.sh prints it as the final step, with a
# " (short alias: tb)" note when it made the alias). Empty when it printed none,
# or named something that is not an absolute path to an executable file. Read
# from the installer, never from `command -v`: the installer runs as a child
# process, so where it put the binary never reaches THIS PATH. A lookup finds
# ~/.local/bin only on the curl|bash path (install.sh prepends it) and ~/bin
# never, and may return an older package-manager copy instead (client-dev#1390).
_cli_reported_path() {
  local line p=""
  [[ -r "${1:-}" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in *"tracebloc CLI installed: "*) p="${line#*tracebloc CLI installed: }" ;; esac
  done <"$1"
  p="${p%$'\r'}"
  p="${p% (short alias:*}"
  case "$p" in /*) ;; *) return 0 ;; esac
  [[ -f "$p" && -x "$p" ]] || return 0
  printf '%s\n' "$p"
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

# _cli_first_install_next_step — the pointer at the install summary's "What to do
# next" (`tracebloc data ingest ./data`). A first install prints that summary; a
# `tracebloc upgrade` runs the full flow and ends on the summary's upgrade line, so
# there the pointer names a step that never comes (client-dev#1642, backend#6787).
# See tb_upgrade_run.
_cli_first_install_next_step() {
  tb_upgrade_run && return 0
  info "Then the 'tracebloc data ingest ./data' step below will work."
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
    TRACEBLOC_CLI_ON_FRESH_PATH=1
    local ver; ver="$(_cli_version_short)"
    # Whether the summary's CTA + this step may say "run it NOW" vs "open a new
    # terminal" — gate on WHERE the CLI landed, not `has tracebloc` (this process's
    # PATH was mutated with ~/.local/bin by install.sh, so it resolves the CLI even
    # when the user's returning shell won't). Only a system dir is unconditionally
    # on that shell's PATH (Bugbot #371).
    if has tracebloc && _cli_usable_in_launch_shell "$(command -v tracebloc 2>/dev/null)"; then
      TB_CLI_USABLE_NOW=1
      # Usable right now AND in new terminals — the fully-clean verdict, collapsed
      # to ONE line (old→new when this was an update), so the step shows a single
      # ✔ instead of an already-present / re-running / installing / ready pileup.
      if [[ -n "${TB_CLI_OLD_VER:-}" && -n "$ver" && "${TB_CLI_OLD_VER}" != "$ver" ]]; then
        # Only claim an upgrade when we CONFIRMED a new version. If the post-install
        # `tracebloc version` probe came back empty ($ver=""), we can't tell whether
        # anything changed — fall through to the neutral "up to date" rather than a
        # bare "updated" with no version to back it up (Bugbot: false updated verdict).
        success "tracebloc CLI updated · v${TB_CLI_OLD_VER} → v${ver}"
      elif [[ -n "${TB_CLI_OLD_VER:-}" ]]; then
        success "tracebloc CLI up to date${ver:+ · v${ver}}"
      else
        success "tracebloc CLI installed${ver:+ · v${ver}}"
      fi
      return 0
    fi
    # Installed and persisted for NEW terminals, but off the PATH of the shell that
    # launched this installer (it fixed its PATH at login, #304). The summary's last
    # line says to open a new terminal (_cli_runnable_now); how to load it here is logged.
    TB_CLI_USABLE_NOW=0
    local rc; rc="$(_cli_rc_for_shell || true)"
    success "tracebloc CLI installed${ver:+ · v${ver}}"
    log "The tracebloc CLI resolves in a new terminal, not in this shell; to load it here: source ${rc:-its rc file}"
    return 0
  fi

  # Installed, but a fresh terminal won't find it (e.g. it landed in
  # ~/.local/bin, which isn't on PATH). Tell the user precisely how to fix it
  # for THEIR shell — not a generic "open a new terminal" that won't help.
  # Not usable now AND a new shell won't resolve it either (case B): the summary
  # CTA must point at the PATH fix below, NOT "open a new terminal" (Bugbot #371).
  TB_CLI_USABLE_NOW=0
  TRACEBLOC_CLI_ON_FRESH_PATH=0
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
  _cli_first_install_next_step
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
  TRACEBLOC_CLI_BIN=""
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
  if has tracebloc && _cli_usable_in_launch_shell "$(command -v tracebloc 2>/dev/null)"; then
    TB_CLI_USABLE_NOW=1
  else
    TB_CLI_USABLE_NOW=0
  fi

  local installer
  installer="$(mktemp)" || { warn "Couldn't install the tracebloc CLI (no temp dir) — your client is set up fine."; return 0; }

  # 1) Download the released installer. A failure here is a download problem,
  #    distinct from an install problem below.
  # curl_secure supplies the TLS floor and the connect timeout; --max-time 120
  # tightens its default deadline so a stalled CDN turns into a clean "install
  # later" failure below instead of hanging the CLI-install step (this call isn't
  # retry-wrapped, and a hang is not a failure the graceful fallback would catch).
  if ! curl_secure -fsSL --max-time 120 "$TRACEBLOC_CLI_INSTALL_URL" -o "$installer" 2>>"${LOG_FILE:-/dev/null}"; then
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
  #    Its output is captured, then appended to the install log, because the
  #    install record needs the path it reports (_cli_reported_path).
  local _cli_out _cli_rc=0
  _cli_out="$(mktemp)" || _cli_out=""
  # Appended, never truncated: without a temp file the fallback is the install log.
  sh "$installer" >> "${_cli_out:-${LOG_FILE:-/dev/null}}" 2>&1 &
  # Set and unset, not a prefix assignment: a prefix on a function can outlive the call.
  _TB_SPIN_QUIET=1
  spin "$!" "Installing the tracebloc CLI..." || _cli_rc=$?
  unset _TB_SPIN_QUIET
  if [[ -n "$_cli_out" ]]; then cat "$_cli_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true; fi
  if [[ "$_cli_rc" -eq 0 ]]; then
    # Recorded where the CLI installer says it put the binary: /usr/local/bin,
    # ~/bin or ~/.local/bin (see _cli_reported_path). No path, no artefact.
    local _cli_path=""
    if [[ -n "$_cli_out" ]]; then _cli_path="$(_cli_reported_path "$_cli_out")"; fi
    if [[ -n "$_cli_path" ]]; then
      tb_record_write binary tracebloc "$_cli_path"
      # The macOS node's login item runs this binary by its absolute path (launchd has
      # no PATH): mac-container.sh's _mac_ct_create_cluster reads it.
      # shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
      TRACEBLOC_CLI_BIN="$_cli_path"
    else
      log "The CLI installer reported no install path; no tracebloc binary recorded."
    fi
    # Self-verify usability from a FRESH terminal and print the single ✔ line
    # (or a shell-correct PATH fix). Non-fatal — always returns 0.
    _verify_tracebloc_cli
  else
    warn "Couldn't install the tracebloc CLI automatically — your client is set up fine."
    hint "Install it later:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
  fi

  rm -f "$installer"
  if [[ -n "$_cli_out" ]]; then rm -f "$_cli_out"; fi
  return 0
}

# require_tracebloc_cli_floor — run right after install_tracebloc_cli: stop the
# install when the CLI this machine is left with is below TB_CLI_MIN_VERSION, the
# floor assess.sh declares (backend#4959). install_tracebloc_cli never fails the
# run: a download or install that does not work keeps the CLI already here. Below
# the floor that CLI cannot find the client this chart installs and the platform
# refuses it, so going on would set up a client the machine's own CLI cannot use.
# Stopping here, before the cluster is touched, leaves the machine as it was.
#
# The CLI is the one _assess_cli_bin resolves, the same one the stop-and-check
# gate reads. No CLI at all is not this check's case: provision_client refuses
# where it needs one, and an install with a supplied credential needs none. A
# version that cannot be read passes, as it does at the gate.
require_tracebloc_cli_floor() {
  # assess.sh holds the floor. Without it this cannot tell, and an install that
  # cannot tell does not go on.
  declare -F _assess_cli_outdated >/dev/null 2>&1 \
    || error "This installer is missing scripts/lib/assess.sh, so it cannot check the tracebloc CLI's version. Run the installer again from its release."
  _assess_cli_outdated || return 0
  local bin ver
  bin="$(_assess_cli_bin)"
  ver="$(_assess_cli_version "$bin")"
  [[ "$bin" == */* ]] || bin="$(command -v "$bin" 2>/dev/null || printf '%s' "$bin")"
  error "The tracebloc CLI on this machine (v${ver}, ${bin}) is older than v${TB_CLI_MIN_VERSION}, the oldest version tracebloc accepts, and it could not be updated.
  Update it:  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh
  then run this installer again."
}

# ── The account's example use case ──────────────────────────────────────────

# _example_switch_on VALUE -- true unless VALUE, trimmed, is "", "0" or "false" in any
# case: the CLI's own rule for its opt-out variables, so either side skips alike.
_example_switch_on() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    '' | 0 | [Ff][Aa][Ll][Ss][Ee]) return 1 ;;
  esac
  return 0
}

# _example_opt_out -- the variable that switches the example use case off, or nothing.
# TRACEBLOC_SKIP_EXAMPLE is its name; TRACEBLOC_NO_EXAMPLE skips it too, as in the CLI.
_example_opt_out() {
  if _example_switch_on "${TRACEBLOC_SKIP_EXAMPLE:-}"; then
    printf 'TRACEBLOC_SKIP_EXAMPLE'
  elif _example_switch_on "${TRACEBLOC_NO_EXAMPLE:-}"; then
    printf 'TRACEBLOC_NO_EXAMPLE'
  fi
  return 0
}

# _example_attended -- a controlling terminal, so a Ctrl-C can reach the example's run:
# /dev/tty opens, the test _login_tty_ok makes. Split out so tests can force either branch.
_example_attended() { { : </dev/tty; } 2>/dev/null; }

# _example_lines -- the example's CLI output, read on stdin: every line into the install
# log, and on screen only its results (the CLI's ✔, ⚠ and ✖ lines), under a live line
# of this pipeline's own (its ticker ends with this subshell).
_example_lines() {
  local line
  tb_live_quiet "Setting up your example use case..."
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >>"${LOG_FILE:-/dev/null}"
    line="${line%$'\r'}"
    case "$line" in
      *✔*) success "${line#*✔ }" ;;
      *⚠*|*✖*) _tb_live_hold; printf '%s\n' "$line"; _tb_live_resume ;;
    esac
  done
  tb_live_done
  return 0
}

# setup_example_use_case -- after a connected install, `tracebloc data ingest --example`
# sets up the account's example use case. The CLI asks tracebloc first, so a re-run
# sets nothing up twice. It never fails the install: every path returns 0.
setup_example_use_case() {
  local cli="" why="" probe=0 rc=0 int_trap="" deadline=""
  [[ "${TRACEBLOC_CLIENT_STATE:-}" == connected ]] || return 0
  ! tb_upgrade_run || return 0
  # In tracebloc's WSL distro the CLI is the Windows host's, and install-wsl.ps1 runs it.
  [[ -z "$(tb_wsl_phase 2>/dev/null)" ]] || return 0
  why="$(_example_opt_out)"
  if [[ -n "$why" ]]; then
    echo ""
    info "Skipping the example use case: ${why} is set."
    return 0
  fi
  # Only a CLI this run signed in is signed in to the account that owns this client;
  # credentials supplied up front sign nothing in.
  if [[ "${TB_CLI_SIGNED_IN:-}" != 1 ]]; then
    log "Example use case: not set up, as this run did not sign the tracebloc CLI in."
    return 0
  fi
  if [[ -n "${TRACEBLOC_CLI_BIN:-}" && -x "$TRACEBLOC_CLI_BIN" ]]; then
    cli="$TRACEBLOC_CLI_BIN"
  elif has tracebloc; then
    cli=tracebloc
  else
    log "Example use case: not set up, as no tracebloc CLI runs here."
    return 0
  fi
  # A CLI without --example refuses the flag even beside --help, and help changes nothing.
  _bounded "${TB_CLI_PROBE_TIMEOUT:-30s}" "$cli" data ingest --example --help </dev/null >/dev/null 2>&1 || probe=$?
  if [[ "$probe" -ne 0 ]]; then
    log "Example use case: not set up, as '${cli} data ingest --example --help' exited ${probe} (124: no answer within ${TB_CLI_PROBE_TIMEOUT:-30s})."
    return 0
  fi
  echo ""
  echo ""
  echo -e "  ${BOLD}Setting up your example use case${RESET}"
  echo ""
  echo "  We'll ingest synthetic data and start a model"
  echo "  training so you can explore tracebloc."
  echo ""
  # Attended, in the foreground and unbounded: _bounded moves it out of the terminal's
  # process group, where a Ctrl-C never reaches it. The CLI exits 130 on one; the
  # installer's INT trap is a no-op meanwhile, since the install is connected and stays
  # done. Unattended, no Ctrl-C can come, so a run that does not end is stopped.
  # Either way its output goes through _example_lines: its results on screen, all of it
  # in the log. The CLI's status is PIPESTATUS[0]: _example_lines returns 0, so the
  # pipeline's own status is the CLI's only under pipefail.
  int_trap="$(trap -p INT)"
  trap ':' INT
  if _example_attended; then
    "$cli" data ingest --example </dev/null 2>&1 | _example_lines && rc=${PIPESTATUS[0]} || rc=${PIPESTATUS[0]}
  else
    deadline="${TRACEBLOC_EXAMPLE_TIMEOUT:-15m}"
    _bounded "$deadline" "$cli" data ingest --example </dev/null 2>&1 | _example_lines && rc=${PIPESTATUS[0]} || rc=${PIPESTATUS[0]}
  fi
  if [[ -n "$int_trap" ]]; then eval "$int_trap"; else trap - INT; fi
  # A Ctrl-C ends _example_lines before its live line does: clear what it drew.
  if _tb_animate; then printf '\r\033[K'; tput cnorm 2>/dev/null || true; fi
  case "$rc" in
    0)
      echo ""
      echo "  Your training results will appear on your"
      echo "  use case in the dashboard."
      echo "" ;;
    130) info "Stopped setting up the example use case." ;;
    *)
      if [[ "$rc" -eq 124 && -n "$deadline" ]]; then
        warn "Stopped setting up the example use case after ${deadline} with no terminal attached — your secure environment is set up fine."
        return 0
      fi
      warn "Couldn't set up the example use case — your secure environment is set up fine."
      log "tracebloc data ingest --example exited ${rc}."
      ;;
  esac
  return 0
}
