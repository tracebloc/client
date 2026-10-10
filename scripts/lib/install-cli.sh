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

# _cli_on_launch_path BIN -> 0 when BIN's directory was on the PATH of the shell
# that started the install (TB_LAUNCH_PATH, captured by install.sh / common.sh
# before either prepends anything). That shell is the one the user types the next
# command into, so a CLI in ~/.local/bin is usable there right away when the user's
# PATH already had ~/.local/bin -- the common case on a re-install. Without this,
# such a user was told "open a new terminal" while their shell already found the
# CLI (backend#5025 O-103). Conservative: an unset or empty TB_LAUNCH_PATH, or a BIN
# that is not an absolute path, is "no". A bootstrap older than common.sh has already
# prepended ~/.local/bin by the time common.sh captures the PATH, so common.sh drops
# that leading entry from the capture instead of trusting it.
_cli_on_launch_path() {
  local bin="${1:-}" dir
  case "$bin" in /*) ;; *) return 1 ;; esac
  [[ -n "${TB_LAUNCH_PATH:-}" ]] || return 1
  dir="${bin%/*}"
  case ":${TB_LAUNCH_PATH}:" in *":${dir}:"* | *":${dir}/:"*) return 0 ;; esac
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
# never, and may return an older brew or pkg copy instead (client-dev#1390).
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
# next" (`tracebloc data ingest ./data`). A full install prints that summary; the
# CLI-only `tracebloc upgrade` path (upgrade_cli_only, TRACEBLOC_CLI_UPGRADE_ONLY=1)
# exits without one, so there the line would name a step that never comes
# (client-dev#1642). upgrade_cli_only closes with its own upgrade line instead.
_cli_first_install_next_step() {
  [[ "${TRACEBLOC_CLI_UPGRADE_ONLY:-0}" == "1" ]] && return 0
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
    _cli_first_install_next_step
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
  spin "$!" "Installing the tracebloc CLI…" || _cli_rc=$?
  if [[ -n "$_cli_out" ]]; then cat "$_cli_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true; fi
  if [[ "$_cli_rc" -eq 0 ]]; then
    # Recorded where the CLI installer says it put the binary: /usr/local/bin,
    # ~/bin or ~/.local/bin (see _cli_reported_path). No path, no artefact.
    local _cli_path=""
    if [[ -n "$_cli_out" ]]; then _cli_path="$(_cli_reported_path "$_cli_out")"; fi
    if [[ -n "$_cli_path" ]]; then
      tb_record_write binary tracebloc "$_cli_path"
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

# upgrade_cli_only — the CLI-only path for an explicit `tracebloc upgrade` on an
# otherwise-healthy machine (INSTALL_STATE_REASON=cli-behind-latest, backend#2253).
#
# The environment is already healthy BY CONSTRUCTION — that is what cli-behind-
# latest means — so there is nothing to reconcile: update ONLY the tracebloc CLI
# (a small, isolated download) and finish. This is the difference between the
# healthy fast-path's old "already set up — no need to run the installer again"
# no-op (which left a below-latest CLI nagging forever) and actually doing the one
# thing the user asked for.
#
# It EXITS the installer (0). Unlike _assess_handoff it does NOT mark the run
# `skipped`: a newer CLI was installed, so this is a real, succeeded install and
# telemetry (already `started` in main) records it as such on the 0 exit.
upgrade_cli_only() {
  info "Your tracebloc environment is healthy — updating just the CLI to the latest release."
  echo ""

  # backend#2679: this path DOWNLOADS + cosign-verifies the CLI (install_tracebloc_cli
  # curl_secure's the installer) and then EXITS — before main()'s own wire_ca_trust
  # (install-k8s.sh) ever runs. Behind a TLS-inspecting proxy that leaves the download
  # or signature check failing x509 on the exact machine where a normal install
  # SUCCEEDS, because the full flow wires CA trust before any tool download (#583). So
  # wire the corporate CA HERE too, before the download — same reason this path already
  # re-surfaces the hand-off's advisories below (it exits before the step that would
  # otherwise do it). Idempotent and a no-op when no CA is configured; guarded like
  # main()'s call so a stale bootstrap without cluster.sh falls through (the download
  # then behaves exactly as it did before this branch existed).
  if declare -F wire_ca_trust >/dev/null 2>&1; then
    wire_ca_trust
  fi

  # The install record may gain the new CLI here, but this path never writes the
  # FIRST one: it reads no cluster, kube context or Helm release, so a record
  # begun here would say Helm never ran. A machine installed before the record
  # existed gets its record on the next full install.
  if declare -F tb_record_path >/dev/null 2>&1 && [[ ! -f "$(tb_record_path)" ]]; then
    TRACEBLOC_RECORD_ARMED=""; TB_RECORD_ARMED=""   # both: the read falls back to the old name
  fi
  # Whatever it writes refreshes the CLI's entry only: CLUSTER_NAME and
  # HOST_DATA_DIR are defaults here, not what the install recorded.
  TB_RECORD_REFRESH_ONLY=1
  # No full-install summary follows this path, so the CLI step must not point at
  # one (_cli_first_install_next_step, client-dev#1642).
  TRACEBLOC_CLI_UPGRADE_ONLY=1

  # install_tracebloc_cli owns the ✔/✖ line and is non-fatal by contract; it also
  # prints the vX -> vY update verdict. Guarded like main()'s own call so a stale
  # bootstrap that didn't fetch this file can't reach an undefined function.
  if declare -F install_tracebloc_cli >/dev/null 2>&1; then
    install_tracebloc_cli
  fi

  # This path exits before _handle_existing_cluster, exactly like the healthy
  # hand-off — so surface the same advisories the hand-off does, or a
  # healthy-but-drifted k3s (#547/#565) or an unschedulable-GPU cluster
  # (client#835) gets no signal on `tracebloc upgrade`. Advisory + guarded.
  declare -F _check_existing_cluster_k8s_version >/dev/null 2>&1 && _check_existing_cluster_k8s_version
  declare -F _check_healthy_cluster_gpu_consistent >/dev/null 2>&1 && _check_healthy_cluster_gpu_consistent
  declare -F _check_existing_cluster_kubelet_config >/dev/null 2>&1 && _check_existing_cluster_kubelet_config
  declare -F _check_existing_cluster_node_count >/dev/null 2>&1 && _check_existing_cluster_node_count

  # The CLI update is the ENTIRE point of this path, so — unlike the full flow,
  # where a CLI hiccup is non-fatal because the client is already connected — a
  # FAILED update here must NOT report success: it would leave the update nag in
  # place while `tracebloc upgrade` looked like it worked (Bugbot). When we know
  # the target (TB_CLI_LATEST, else TRACEBLOC_CLI_LATEST -- the name the CLI sets
  # comes first, as in assess.sh) and the CLI is verifiably STILL behind it, exit
  # non-zero (install_tracebloc_cli has already printed how to retry). Otherwise
  # — updated, or target/version unreadable so we can't PROVE a failure — exit 0.
  local latest now
  latest="${TB_CLI_LATEST:-${TRACEBLOC_CLI_LATEST:-}}"; latest="${latest#v}"
  now="$(_cli_version_short 2>/dev/null || true)"; now="${now#v}"
  if [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [[ "$now" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
     && _version_lt "$now" "$latest"; then
    warn "Couldn't update the tracebloc CLI to ${latest} — still on ${now}. The update reminder will keep showing until it succeeds."
    exit 1
  fi
  # The upgrade's closing line, in place of the first-install next steps this
  # path never reaches (client-dev#1642). The version is the CLI's own answer;
  # unreadable, the line still says what did not change.
  if [[ -n "$now" ]]; then
    info "Now on v${now}; your environment is unchanged."
  else
    info "Your environment is unchanged."
  fi
  _tb_done=1   # an intended exit 0 under install_cleanup (tb_exit_rc, client-dev#1752)
  exit 0
}
