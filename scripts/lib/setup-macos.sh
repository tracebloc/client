#!/usr/bin/env bash
# =============================================================================
#  setup-macos.sh — macOS prerequisites: Homebrew, Docker Desktop, kubectl,
#                   k3d, helm
# =============================================================================

install_homebrew() {
  if ! has brew; then
    local brew_script
    brew_script="$(mktemp)"
    curl_secure -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
      -o "$brew_script"
    # #561: bounded so a wedged Homebrew install (network stall, a hung Command
    # Line Tools fetch) can't hang the installer forever behind the spinner.
    # Generous (30m) — a fresh Mac may pull the Xcode CLT here.
    spin_cmd_bounded 1800 "Installing Homebrew…" env NONINTERACTIVE=1 /bin/bash "$brew_script"
    rm -f "$brew_script"
    if [[ "$ARCH" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      grep -q 'homebrew' "$HOME/.zprofile" 2>/dev/null || \
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    log "Homebrew installed."
  else
    log "Homebrew already present."
  fi
}

_kill_lingering_docker() {
  # _docker_answers_bounded, not _docker_answers: this is the wedged-Docker cleanup
  # path, and _docker_answers bounds through _bounded, which is a no-op on a stock
  # Mac (no coreutils) — so a bare, unbounded `docker info` would hang exactly here
  # (Bugbot #744). The background-PID bound needs no coreutils.
  if ! _docker_answers_bounded "Checking for a running Docker…" "${TB_DOCKER_PROBE_TIMEOUT:-10}" && pgrep -xq "Docker Desktop"; then
    log "Lingering Docker Desktop process detected — cleaning up…"
    osascript -e 'quit app "Docker"' 2>/dev/null || true
    sleep 2
    if pgrep -xq "Docker Desktop"; then
      pkill -x "Docker Desktop" 2>/dev/null || true
      sleep 2
    fi
    if pgrep -xq "Docker Desktop"; then
      pkill -9 -x "Docker Desktop" 2>/dev/null || true
      sleep 1
    fi
    log "Lingering Docker process cleared."
  fi
}

_has_gui_session() {
  # /dev/console is owned by the GUI-logged-in user on macOS.
  # On headless Macs (EC2, CI) or when no user is logged into the desktop,
  # it's owned by "root". This is more reliable than checking WindowServer,
  # which runs even on headless EC2 Mac instances.
  local console_user
  console_user="$(stat -f '%Su' /dev/console 2>/dev/null || echo '')"
  [[ -n "$console_user" && "$console_user" != "root" ]]
}

# Is the current user a macOS administrator (or root)? Admin group members can sudo
# (default /etc/sudoers: `%admin ALL=(ALL) ALL`); a managed/standard account can't.
# Overridable for tests via TB_MACOS_ADMIN_GROUPS.
_macos_user_is_admin() {
  [ "$(id -u)" -eq 0 ] && return 0
  local groups="${TB_MACOS_ADMIN_GROUPS:-$(id -Gn 2>/dev/null)}"
  # Capture-then-match, NOT `printf … | grep -qx` (#680's transform; its fleet
  # sweep of this hazard did not reach setup-macos.sh). `grep -q` closes the pipe
  # on its FIRST match and `admin` sits near the FRONT of a macOS group list, so
  # printf can take SIGPIPE while still writing — and `set -o pipefail` then
  # makes the pipeline 141, which the caller reads as "not an administrator" and
  # answers with the managed-Mac remedy on a machine that is perfectly fine.
  # Match position, not producer size, is the trigger; a directory-bound Mac with
  # a long group list makes it a real race. This is the FIRST thing step b runs.
  local _glist; _glist="$(printf '%s\n' $groups)"
  grep -qx admin <<<"$_glist"
}

# Fail FAST on a no-admin Mac with a named, IT-facing remedy — the macOS analog of
# Linux prepare-host (#430). Without this, a managed/standard account fell through to
# preflight_sudo's generic "sudo authentication failed" after a wasted prompt. Admins
# (and root) pass through untouched to the normal sudo priming.
_macos_require_admin() {
  _macos_user_is_admin && return 0
  # Be accurate about what actually unblocks this (#430 Bugbot): re-running as the same
  # non-admin account hits this gate again, and there is NO macOS prepare-host (it errors
  # on Darwin). The install steps (Docker, brew, /usr/local/bin) genuinely need admin, so
  # the only real remedies are to gain admin on this account, or to install from an
  # account that already has it.
  warn "This Mac account isn't an administrator, but installing Docker + the tracebloc runtime on macOS needs admin rights (there is no non-admin macOS path yet)."
  hint "Ask your IT/admin to do ONE of these:"
  hint "  • grant THIS account administrator rights (System Settings → Users & Groups → this user → \"Allow this user to administer this computer\"), then re-run as yourself, or"
  hint "  • have an administrator run this installer on this Mac from their OWN admin account."
  error "Administrator rights required on this Mac — grant this account admin (or install from an admin account), then re-run."
}

# Does this Mac support Apple Virtualization.framework (colima --vm-type vz)? It needs
# macOS 13+ (Ventura); Rosetta x86_64 translation (--vz-rosetta) rides on VZ. Below 13,
# colima falls back to its QEMU default (amd64 still runs, just slower). Overridable
# for tests via TB_MACOS_VER (#433).
_macos_supports_vz() {
  local v major
  v="${TB_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null)}"
  major="${v%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 13 ]
}

# Has a colima VM already been created (running OR stopped)? `colima list --json` emits
# one JSON line per instance and nothing when there are none. colima REFUSES to change
# vmType on an existing instance, so we only request VZ+Rosetta on a fresh start (#433
# Bugbot). Mockable via the colima function in tests.
_colima_instance_exists() {
  [[ -n "$(colima list --json 2>/dev/null)" ]]
}

_install_docker_colima() {
  log "Headless environment detected (no GUI session) — using Colima as Docker runtime."

  if ! has docker; then
    # #561: bounded so a wedged brew (network stall) can't hang forever.
    spin_cmd_bounded 900 "Installing Docker…" brew install docker
    success "Docker"
  else
    success "Docker"
  fi

  if ! has colima; then
    # #561: bounded so a wedged brew (network stall) can't hang forever.
    spin_cmd_bounded 900 "Installing container runtime…" brew install colima
  fi

  if _docker_answers_bounded "Checking Docker…" "${TB_DOCKER_PROBE_TIMEOUT:-10}"; then
    success "Docker running."
    return
  fi

  # Colima VM memory is DERIVED from physical RAM (#428): _macos_vm_mem_gb gives
  # min(half of physical, the clamped recommendation), never below the preflight
  # floor (~5 GB: control plane + k3s + OS). The old hard-coded 6 was too big for a
  # ≤8 GB Mac to spare and never scaled up. COLIMA_MEMORY overrides per box; the
  # helper lives in preflight.sh, sourced before this in the bootstrap.
  local _colima_mem="${COLIMA_MEMORY:-$(_macos_vm_mem_gb)}"
  log "Colima memory budget: ${_colima_mem} GB"
  # Build the arg vector so the arch flags append cleanly (bash-3.2-safe: the array is
  # never empty, so "${_colima_args[@]}" is fine under set -u). On Apple Silicon the
  # amd64-only client images need x86_64 acceleration; with VZ (macOS 13+) use Rosetta
  # — the fast path that matches Docker Desktop's "Use Rosetta for x86_64/amd64
  # emulation". Without these flags colima's default arm64 QEMU VM runs amd64 images
  # slowly or not at all, which the post-Docker smoke (assert_amd64_emulation) catches
  # regardless (#433). Older macOS keeps the QEMU default.
  local -a _colima_args=( start --cpu "${COLIMA_CPU:-4}" --memory "$_colima_mem" --disk "${COLIMA_DISK:-60}" )
  # Only request VZ+Rosetta on a FRESH instance: colima rejects a vmType change on an
  # existing VM, so forcing --vm-type vz onto a prior QEMU instance (earlier install or
  # reboot) would abort the start (#433 Bugbot). A pre-existing VM is started as-is; if
  # its amd64 emulation is broken, the post-Docker smoke (assert_amd64_emulation) names
  # the `colima delete && colima start --vm-type vz --vz-rosetta` recreate remedy.
  if [[ "$ARCH" == "arm64" ]] && _macos_supports_vz && ! _colima_instance_exists; then
    _colima_args+=( --vm-type vz --vz-rosetta )
    log "Apple Silicon + macOS 13+ (fresh VM): starting Colima with VZ + Rosetta for amd64 acceleration."
  fi
  # #561: bounded so a hung colima start (stale VZ VM) can't hang forever.
  spin_cmd_bounded 900 "Starting Docker runtime…" colima "${_colima_args[@]}"

  if ! _docker_answers_bounded "Verifying Docker started…" "${TB_DOCKER_PROBE_TIMEOUT:-10}"; then
    error "Docker did not start. Try running 'colima status' to investigate."
  fi

  success "Docker running."
}

# Offer to raise an EXISTING Colima VM that is below the training floor
# (backend#2221). Returns 0 whether or not anything was changed -- this is an
# offer, never a gate.
#
# WHY THIS EXISTS. #428 sizes a FRESH Colima VM from physical RAM, so a first
# install already gets a sensible budget. An existing VM does not: the installer
# starts it as-is, preflight warns that it is too small, and the user is left to
# fix it by hand. That warning is the state backend#2221 calls out -- *"the
# installer states an absolute minimum VM allocation and offers to fix it. We
# already write .wslconfig on Windows; macOS needs the equivalent."*
#
# WHY COLIMA AND NOT DOCKER DESKTOP, which is the asymmetry to understand here.
# Colima is a CLI with documented flags: `colima stop && colima start --memory N`
# is a supported operation whose effect can be MEASURED afterwards. Docker
# Desktop's VM size lives in a settings file, and until 2026-09-17 this path was
# deliberately Colima-only: the memory key's name had never been read off a real
# installation, and a default install does not carry it at all (Docker persists
# only what the user changed; a fresh settings-store.json held ten keys and none
# was memory), so a guessed key would have produced an installer that SAYS it
# raised the VM and did nothing. The key has since been read from a live Desktop
# (`"MemoryMiB": 12288` beside `"Cpus": 6` in
# ~/Library/Group Containers/group.com.docker/settings-store.json, Desktop 4.4x,
# engine 29.7), so _offer_desktop_memory_raise below edits exactly that key --
# replacing it when present, inserting it when the store has never carried one --
# and MEASURES the result the same way the Colima path does. Anything it cannot
# prove (no store, no quit, no restart, a read-back that disagrees) refuses and
# leaves the preflight's instruction standing.
#
# CONSENT IS REQUIRED, because this stops the user's container runtime -- every
# running container goes down. The ticket asks for it explicitly and it is the
# right bar for a destructive-adjacent action:
#   * no usable TTY (CI, `curl | bash`) -> print the manual command and return.
#     A non-interactive run must never restart a runtime nobody asked it to.
#   * default is NO. A bare Enter declines.
#   * TRACEBLOC_ASSUME_YES=1 opts in for an unattended install that WANTS this --
#     for the FLOOR raise, whose VM would OOM anyway. A RUNG raise stops a VM that
#     runs the client (only training cannot schedule), so unattended it is taken
#     only when COLIMA_MEMORY pins the size: the flag consents to the install, not
#     to stopping a working runtime (tracebloc-review on #1090).
#
# AND IT RE-PROBES. The success line is emitted only after `docker info` reports
# the new figure, because "I ran the command" and "the VM is bigger" are
# different claims and only the second one is worth printing.
# Is Colima the runtime `docker` is actually talking to?
#
# WHY THIS IS NOT THE SAME QUESTION as "is Colima installed and does an instance
# exist" (Cursor Bugbot Medium on #832). A headless Mac can have Docker Desktop up
# via VNC AND a leftover, stopped Colima instance. The memory figure then comes
# from DESKTOP's VM, while a "yes" would stop/start Colima and switch the docker
# context to it -- solving a problem the user does not have, on a runtime they were
# not using, and moving their Docker out from under them.
#
# The active CONTEXT is the honest signal: it is what `docker` resolves through,
# so it names the runtime the measured budget actually belongs to. Anything
# unreadable answers "not Colima", which declines to act -- the safe direction for
# a function whose action stops a container runtime.
#
# EXACTLY `colima`, NOT `colima-*` (Cursor Bugbot High + @LukasWodka +
# @saqlainsyed007 on #832). An earlier version accepted named profiles, which was
# half a feature: every command in the raise path runs profile-less, and `colima
# stop` / `colima start` with no `--profile` act on **default**. So an active
# context of `colima-profile2` measured profile2's VM and restarted `default` --
# stopping a VM the user was not using, activating its context, and leaving the
# measured one untouched. Same class as the wrong-runtime bug this guard was added
# to fix, one level in.
#
# Declining is the smaller and more defensible of the two fixes, and it is the same
# reasoning this function already applies to an unreadable context: a named profile
# is another "I cannot act on this safely" case. It also settles @saqlainsyed007's
# second site -- `_colima_instance_exists` is true if ANY instance exists, so it
# never established that the instance about to be stopped is the one measured.
# Requiring the default context makes those the same instance by construction.
_colima_is_active_runtime() {
  local ctx
  ctx="$(docker context show 2>/dev/null)" || return 1
  [ "$ctx" = "colima" ]
}

_offer_colima_memory_raise() {
  [[ "${OS:-$(uname -s)}" == "Darwin" ]] || return 0
  has colima || return 0
  _colima_instance_exists || return 0
  # The measured budget must belong to the runtime we are about to restart.
  if ! _colima_is_active_runtime; then
    # Say so for the one case an operator can act on themselves, rather than
    # skipping in silence: a named profile is a deliberate setup, and the command
    # that would work on it is not the one this function runs.
    local _ctx
    _ctx="$(docker context show 2>/dev/null)" || _ctx=""
    case "$_ctx" in
      colima-*)
        # Plain single quotes: the '\'' concatenation idiom is for a SINGLE-quoted
        # string, and inside double quotes it emits a literal backslash (Bugbot).
        hint "Docker is using the Colima profile '${_ctx#colima-}'. Raise it yourself with: colima stop --profile ${_ctx#colima-} && colima start --profile ${_ctx#colima-} --memory <GB>"
        ;;
    esac
    return 0
  fi

  local current_kb current_mib target_gb current_gb
  current_kb="$(_pf_runtime_mem_kb)"
  [[ "$current_kb" =~ ^[0-9]+$ && "$current_kb" -gt 0 ]] || return 0
  current_mib=$(( current_kb / 1024 ))
  # GRADED IN MiB WITH THE GRACE, never rounded to whole GB first (Cursor Bugbot
  # High on #832). preflight.sh says why in its own words: "a VM configured to
  # exactly the documented floor reports a few hundred MiB less as guest MemTotal,
  # and rounding that to whole GB first would misgrade it as sub-floor". I did
  # exactly that -- so a Colima VM set to the documented 5 GB floor reported ~4.7
  # GiB, truncated to 4, and this path prompted to "fix" a healthy runtime. Under
  # TRACEBLOC_ASSUME_YES=1 it would have restarted one unasked.
  #
  # `_pf_display_gb_from_mib` adds the grace back before dividing, so `current_gb`
  # is the CONFIGURED size rather than the guest's short report. That also settles
  # @LukasWodka's round-down wrinkle on the recovery path for free: restoring at
  # this figure restores what the VM was actually set to, so the accepted
  # "restores slightly smaller" trade is no longer being made at all.
  current_gb="$(_pf_display_gb_from_mib "$current_mib")"
  target_gb="${COLIMA_MEMORY:-$(_macos_vm_mem_gb)}"
  [[ "$target_gb" =~ ^[0-9]+$ && "$target_gb" -gt 0 ]] || return 0

  # Only when it is actually short — for one of TWO reasons, graded in MiB with
  # the grace exactly as _pf_runtime_mem_status grades them:
  #   floor  below PF_MIN_MEM_GB: the client itself OOMs (the original #2221 case)
  #   rung   at or above the floor but below the smallest training rung's budget
  #          (PF_WARN_MEM_GB, derived from the generated VM constant; clamped to
  #          this host the way the preflight clamps it): the client runs, and
  #          every training pod stays Pending. RFC-BACKEND-664 §P4 names raising
  #          the VM as the remedy; Docker Desktop gets the same offer through its
  #          settings store in _offer_desktop_memory_raise below.
  local rung_eff short_reason
  rung_eff="$(_pf_clamp_mem_gb "$PF_WARN_MEM_GB")"
  if (( current_mib < PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB )); then
    short_reason="floor"
  elif [[ "$rung_eff" =~ ^[0-9]+$ ]] && (( current_mib < rung_eff * 1024 - PF_VM_MEM_GRACE_MIB )); then
    short_reason="rung"
  else
    return 0
  fi

  # THE SUB-FLOOR EXPLANATION COMES BEFORE THE "worth a restart" GUARD (Cursor
  # Bugbot on #832). It used to sit after `(( target_gb > current_gb ))`, so a VM
  # ALREADY at the inadequate target returned silently and the one-shot
  # explanation -- the whole point of this branch -- never printed for the case
  # that needs it most.
  #
  # `_macos_vm_mem_gb` applies the host cap AFTER the safe floor
  # (preflight.sh:189-192), so on a small host the target comes back BELOW the
  # floor: a 6 GB Mac yields 4 against a floor of 5. Raising to that cannot fix
  # anything, so say why once instead of prompting forever.
  #
  # AND IT NAMES THE RIGHT CULPRIT. `target_gb` can come from COLIMA_MEMORY, in
  # which case blaming the Mac is wrong -- the operator chose a sub-floor budget
  # and only they can raise it. Two different problems deserve two messages.
  # Floor reason only: a VM that is above the floor has nothing to be told about
  # the floor, whatever the derived target says — the rung path below explains
  # its own non-offers in its own words.
  if [[ "$short_reason" == "floor" ]] && (( target_gb < PF_MIN_MEM_GB )); then
    if [[ -n "${COLIMA_MEMORY:-}" ]]; then
      hint "COLIMA_MEMORY is set to ${COLIMA_MEMORY} GB, below the ${PF_MIN_MEM_GB} GB tracebloc needs to train. Raise or unset it."
    else
      hint "This Mac cannot spare ${PF_MIN_MEM_GB} GB for Docker (the most it can give is ${target_gb} GB), so raising the VM would not fix it. Training needs a larger machine."
    fi
    return 0
  fi

  # NO "is the raise worth a restart" GUARD HERE EITHER, for the same arithmetic.
  # `(( target_gb > current_gb ))` is unreachable on the floor path (with grace=512
  # and floor=5, short means `current_mib < 4608`, so current_gb is at most 4 while
  # the target is at least 5) and equally unreachable on the rung path: short means
  # `current_mib < rung_eff*1024 - grace`, so `current_gb = (current_mib+512)/1024`
  # is below rung_eff, and rung_eff never exceeds PF_WARN_MEM_GB, which the target
  # below must reach. What the rung path DOES need is a "does the raise reach the
  # rung budget" guard: a sub-rung VM is already a working runtime, and stopping
  # every container to move it from 6 to 8 GB against a 9 GB rung would restart it
  # and still leave training Pending. Two honest non-offers, each naming its cause:
  # the operator's COLIMA_MEMORY pin, or a Mac that cannot spare the budget. The
  # macos-vm-memory.bats fixtures for both exercise this line.
  if [[ "$short_reason" == "rung" ]]; then
    if (( target_gb < PF_WARN_MEM_GB )); then
      if [[ -n "${COLIMA_MEMORY:-}" ]]; then
        hint "COLIMA_MEMORY is set to ${COLIMA_MEMORY} GB, below the ${PF_WARN_MEM_GB} GB the smallest training run (4 GiB) needs beside the platform. Raise or unset it to train locally."
      else
        hint "This Mac cannot give Docker the ${PF_WARN_MEM_GB} GB the smallest training run (4 GiB) needs beside the platform (the most it can spare is ${target_gb} GB), so the VM is left as it is. It runs the client; train on a larger machine."
      fi
      return 0
    fi
  fi

  local cmd="colima stop && colima start --memory ${target_gb}"
  if [[ "$short_reason" == "rung" ]]; then
    warn "Docker's Colima VM has ${current_gb} GB — enough to run the client, but the smallest training run (4 GiB) needs a ${PF_WARN_MEM_GB} GB budget once the kubelet reservation, k3s addons, control plane and CronJobs are counted; training pods would stay Pending."
  else
    warn "Docker's Colima VM has ${current_gb} GB — below the ${PF_MIN_MEM_GB} GB tracebloc needs to train."
  fi

  if [[ "${TRACEBLOC_ASSUME_YES:-}" != "1" ]]; then
    if ! _tty_usable; then
      hint "Raise it with: ${cmd}"
      return 0
    fi
    local reply=""
    prompt_header "Raise the Colima VM to ${target_gb} GB now?"
    hint "This STOPS the VM — every running container goes down — then starts it with more memory."
    _read_sanitized "  Raise it? [y/N] " reply
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) ;;
      *) hint "Left alone. Raise it later with: ${cmd}"; return 0 ;;
    esac
  elif [[ "$short_reason" == "rung" && -z "${COLIMA_MEMORY:-}" ]]; then
    # TRACEBLOC_ASSUME_YES CONSENTS TO THE INSTALL, NOT TO THIS INTERRUPTION
    # (tracebloc-review on #1090). The floor raise it always accepted stops a VM
    # that would OOM anyway. A sub-rung VM is a working runtime -- the client is
    # up and so is everything else in it, and the Tier 0 call site reaches this
    # branch with the VM already running -- so stopping it unasked, for training
    # capacity nobody asked about, is a different decision from the one the flag
    # was written for. An explicit COLIMA_MEMORY names the size and takes the
    # restart with it; without it the unattended run says what it is not doing.
    hint "Not raised unattended: the VM is running, and the raise stops it with every container in it. To accept that in an unattended run, pin the size (COLIMA_MEMORY=${target_gb}) or run: ${cmd}"
    return 0
  fi

  # Bounded like every other colima call here (#561): a wedged VZ VM must not
  # hang the install forever.
  if ! spin_cmd_bounded 900 "Stopping the Docker runtime…" colima stop; then
    # "LEFT AS IT WAS" HAS TO BE CHECKED, NOT ASSUMED (Cursor Bugbot High on #832).
    # A failed `colima stop` is one thing; a TIMED-OUT one is another, and the
    # bounded wrapper reports both the same way. A timeout can leave the VM
    # half-down, so claiming the VM is untouched and returning 0 lets the install
    # continue against a dead runtime -- the same failure the start path already
    # owns, one branch over.
    # BOUNDED WITHOUT coreutils (backend#2521). A bare `docker info` here is the
    # worst possible place for an unbounded probe: this branch is reached exactly
    # when a timed-out stop may have left the VM half-down, which is also when the
    # daemon is most likely wedged. The earlier version probed via `_docker_answers`,
    # believing it bounded — but `_docker_answers` bounds through `_bounded`, which
    # runs the bare command when neither timeout(1) nor gtimeout(1) is present, and
    # NEITHER ships on stock macOS: the one platform this Darwin-only path runs on.
    # So the bound silently vanished and a headless install froze here with no
    # spinner, never reaching the restore below (Cursor Bugbot High, PR #838).
    # `_docker_answers_bounded` bounds via spin's own background-pid + kill
    # deadline, which needs no coreutils, so a wedged daemon (no answer in time)
    # now falls through to the restore instead of hanging.
    if _docker_answers_bounded "Checking whether Docker is still up…" "${TB_DOCKER_PROBE_TIMEOUT:-10}"; then
      warn "Could not stop Colima; the VM is still running. Raise it manually: ${cmd}"
      return 0
    fi
    warn "Colima did not stop cleanly and Docker is not responding; restoring it."
    if spin_cmd_bounded 900 "Restoring the Docker runtime…" colima start --memory "$current_gb"; then
      warn "Docker is back at ${current_gb} GB. Raise it manually when you can: ${cmd}"
      return 0
    fi
    error "Colima did not stop cleanly and would not restart, so Docker is down. Recover with: colima start --memory ${current_gb} (or 'colima delete && colima start' if the VM is wedged), then re-run the installer."
  fi
  if ! spin_cmd_bounded 900 "Starting it with ${target_gb} GB…" colima start --memory "$target_gb"; then
    # WE STOPPED IT, SO WE OWN GETTING IT BACK (Cursor Bugbot High on #832). The
    # first version warned and returned 0, so the install carried on with Docker
    # DOWN -- and on the already-running headless path control then fell through
    # to Docker Desktop startup, so the operator got a Desktop error on a Colima
    # machine instead of a recoverable Colima failure.
    #
    # Try the plain start first: the most likely cause is the machine cannot honour
    # the larger budget, and the VM that was working a moment ago still can.
    # RESTORED EXPLICITLY, not implicitly (Cursor Bugbot High + both reviewers on
    # #832). A bare `colima start` relies on the previous configuration still being
    # on disk, and this function has no evidence of that -- Bugbot reads Colima as
    # persisting CLI flags before the VM boots, which would make a bare retry the
    # same failing size and leave Docker down. Passing the size we measured is
    # correct under either reading and costs nothing.
    #
    # It rounds DOWN by a few hundred MiB, and that is an accepted trade rather than
    # an oversight: `current_gb` comes from MemTotal, which a guest reports below its
    # configured size. Reading the configured value would mean parsing
    # ~/.colima/<profile>/colima.yaml -- and this PR already declined to guess
    # Docker Desktop's on-disk schema for exactly that reason, so guessing Colima's
    # would be inconsistent. This is a recovery path whose job is to get Docker
    # back, not to restore byte-exact sizing.
    warn "Colima would not start with ${target_gb} GB; restoring the previous VM at ${current_gb} GB."
    if spin_cmd_bounded 900 "Restoring the Docker runtime…" colima start --memory "$current_gb"; then
      warn "Docker is back at ${current_gb} GB. Raise it manually when the machine can spare it: ${cmd}"
      return 0
    fi
    # Recovery failed too. HARD FAIL rather than continue: every later step needs
    # Docker, this function is what stopped it, and a run that proceeds from here
    # fails later with a message about something else entirely.
    error "Colima did not restart after the memory change and Docker is down. Recover with: colima start --memory ${current_gb} (or 'colima delete && colima start' if the VM is wedged), then re-run the installer."
  fi

  # RE-PROBED, not assumed. A start that succeeded and a VM that grew are
  # different facts, and only the second is worth a success line.
  # AND A PROBE THAT DID NOT ANSWER IS NEITHER (Bugbot on #1101): the `else` used
  # to print "still reports ${current_gb} GB" for both a VM that measurably did
  # not grow AND a runtime that said nothing at all -- one sentence asserting a
  # size nobody read, with the number carried over from before the restart. They
  # are separated now, and the measured arm prints the size it measured.
  local new_gb; new_gb="$(_runtime_probed_gb)"
  if [[ -z "$new_gb" ]]; then
    warn "Colima restarted but did not answer when asked what its VM has, so the new size was not measured. Check 'colima status' and raise it manually: ${cmd}"
  elif (( new_gb > current_gb )); then
    success "Colima VM raised to ${new_gb} GB."
  else
    warn "Colima restarted but still reports ${new_gb} GB. Check 'colima status' and raise it manually: ${cmd}"
  fi
  return 0
}

# ── Docker Desktop for Mac: the same offer, through Desktop's settings store ──
#
# WHERE THE BUDGET LIVES. Desktop keeps its VM size as `"MemoryMiB": <n>` in
# ~/Library/Group Containers/group.com.docker/settings-store.json (older releases:
# settings.json in the same directory), read off a real installation -- see the
# header. Desktop reads the file when it starts and rewrites it when a setting
# changes, so the order is quit -> edit -> relaunch; an edit under a running
# Desktop can be overwritten by its next write.
#
# THE OLDER FILE CARRIES THE OLDER SPELLING (Bugbot on #1101). The rename to
# settings-store.json came with PascalCase keys; the settings.json this path falls
# back to for older Desktops keys the same number as `"memoryMiB"`. Editing only
# the PascalCase spelling there did not fail loudly -- the key looked absent, a
# second one Desktop does not read was inserted, and the quit and relaunch were
# spent on a raise that could not happen. So the SPELLING IS READ OFF THE STORE,
# never assumed: _desktop_memory_key below, and the editor matches the family.
#
# TEXT, NOT A JSON ROUND-TRIP: one anchored substitution (or one inserted line
# after the opening brace, when the key was never persisted) leaves every other
# byte as it was. The Windows hook in the e2e harness learned why the hard way: a
# JSON round-trip flattens one-element arrays. And the write is PROVEN by reading
# the file back before Desktop is relaunched on it.
_desktop_settings_store() {
  local dir="$HOME/Library/Group Containers/group.com.docker"
  if [[ -f "$dir/settings-store.json" ]]; then printf '%s' "$dir/settings-store.json"
  elif [[ -f "$dir/settings.json" ]]; then printf '%s' "$dir/settings.json"
  else return 1; fi
}
# Which spelling of the VM-size key this store uses. THE FILE IS THE AUTHORITY and
# is asked first: a store that already carries one of the two spellings gets that
# one back, whatever its name, because the key Desktop reads is the key Desktop
# wrote. Only a store carrying NEITHER -- nothing has ever been persisted -- falls
# back to the file name, which is the one thing left that says which Desktop
# generation wrote it: settings.json is the pre-rename file and keys the number as
# `memoryMiB`; settings-store.json, and anything else, as `MemoryMiB`.
#
# The exact spelling matters to the operator too, not just to the editor: every
# message below that tells someone to set the key by hand names THIS, never a
# literal, or it sends them to a key their Desktop does not have.
_desktop_memory_key() {          # <store text> <store path> -> MemoryMiB | memoryMiB
  local text="$1" store="$2"
  if   [[ "$text" =~ \"MemoryMiB\"[[:space:]]*: ]]; then printf 'MemoryMiB'
  elif [[ "$text" =~ \"memoryMiB\"[[:space:]]*: ]]; then printf 'memoryMiB'
  elif [[ "${store##*/}" == "settings.json" ]];    then printf 'memoryMiB'
  else printf 'MemoryMiB'; fi
}
# Is Docker Desktop the runtime `docker` is actually talking to? The context is
# `desktop-linux` on a current Desktop; an older install answers on `default`, in
# which case the engine's own OperatingSystem string decides. Anything else --
# colima, a remote context, unreadable -- is "not Desktop", and this path declines.
#
# THREE OUTCOMES, NOT TWO (bounded-reads-propagate.bats, and Bugbot on #1101):
#   0  Desktop is the runtime
#   1  another runtime is, or the engine answered and is not Desktop
#   2  could not tell -- the bounded read hit its deadline, which is neither
#      answer, and the caller says so instead of silently skipping the offer
# AND ONE NON-OUTCOME, the same 3 the two probes above use (Bugbot on #1101):
#   3  nothing was probed at all, because no temp file could be created. This was
#      2, which made a failed `mktemp` indistinguishable from a fired deadline and
#      had the caller announce a timeout that never happened -- "Docker did not
#      answer within 10s" about a read that was never issued. Callers word 3
#      through _desktop_unprobed_words, never as a Docker state.
_desktop_is_active_runtime() {
  local ctx
  ctx="$(docker context show 2>/dev/null)" || return 1
  case "$ctx" in
    desktop-linux) return 0 ;;
    default)
      # BOUNDED, like every daemon read in scripts/lib/ (#744, client#984): the
      # engine's OperatingSystem string is the one thing that says whether the
      # `default` context is Desktop's, and a wedged daemon must not hang the offer.
      local out rc=0 verdict=1
      out="$(mktemp)" || return 3
      # `_bounded_capture` keeps stderr with stdout, and a CLI plugin warning there
      # must not hide the engine's answer (Bugbot on #1101): the answer is a whole
      # LINE that reads exactly "Docker Desktop", wherever the noise lands. `grep`
      # reads the FILE -- no pipe, so no early-close under pipefail.
      _bounded_capture "${TB_DOCKER_PROBE_TIMEOUT:-10}" "$out" docker info --format '{{.OperatingSystem}}' || rc=$?
      if (( rc == 0 )); then
        grep -qx 'Docker Desktop' "$out" && verdict=0
      elif (( rc == 124 )); then
        verdict=2          # the deadline fired: the engine neither confirmed nor denied
      fi                   # any other status: docker answered, and it failed -- not Desktop's engine
      rm -f "$out"
      return "$verdict" ;;
    *) return 1 ;;
  esac
}
# Ask Desktop to quit and wait, bounded, until no Desktop process is left. The
# graceful quit is the one that lets Desktop flush its own state; this path never
# kills it, because a killed Desktop can rewrite the store on its next start from
# whatever it held in memory -- exactly the write this edit must not race.
#
# Asking for the backend BY NAME is the part that has to be done carefully
# (Bugbot on #1101): Darwin caps a process's `comm` at MAXCOMLEN (16) chars --
# `p_comm[MAXCOMLEN+1]` in `struct extern_proc` -- and `pgrep` without `-f`
# matches that truncated name. "com.docker.backend" is 18, so `pgrep -xq
# "com.docker.backend"` can NEVER match, whatever is running: the wait would
# return "gone" the moment the GUI exited, while the backend was still flushing
# the very keys this edit must not race. The GUI's own "Docker Desktop" is 14
# and matches fine.
#
# Two probes, OR'd, because over-detection is the safe direction here (it costs
# a wait that times out and warns; under-detection costs the operator's store):
#   * the truncated `comm`, DERIVED from the real name rather than typed, so a
#     rename cannot leave a stale 16-char literal behind. `-x` is kept -- an
#     exact match on the truncated name, not a substring;
#   * the executable PATH, which `-f` reads off the full argv and does not
#     truncate, so this still answers if a future Desktop reports a different
#     `comm` than its binary name.
_desktop_backend_running() {   # 0 iff Docker Desktop's backend process is alive
  pgrep -xq "$(printf '%.16s' com.docker.backend)" && return 0
  pgrep -fq '/Docker\.app/Contents/MacOS/com\.docker\.backend'
}
_desktop_processes_gone() {    # 0 iff NEITHER the GUI nor the backend is alive
  ! pgrep -xq "Docker Desktop" && ! _desktop_backend_running
}
# Ask Desktop to quit and wait, bounded, until no Desktop process is left. The
# graceful quit is the one that lets Desktop flush its own state; this path never
# kills it, because a killed Desktop can rewrite the store on its next start from
# whatever it held in memory -- exactly the write this edit must not race.
_desktop_quit_and_wait() {   # <polls of 2s> -> 0 once "Docker Desktop" and com.docker.backend are gone
  local polls="$1" i
  osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
  for (( i = 0; i < polls; i++ )); do
    if _desktop_processes_gone; then return 0; fi
    sleep 2
  done
  _desktop_processes_gone
}
# Write <content> to the store WITHOUT aborting the installer (Bugbot on #1101):
# under `set -e` a bare `printf > "$store"` that fails -- permissions, a full disk,
# an ACL on the group container -- exits right there, with Desktop already quit
# and the store possibly truncated (`>` truncates first). So the write goes to a
# sibling temp file and is moved into place atomically, every step is a
# condition rather than a statement, and the caller decides what a failure
# means. Returns non-zero when the store does not hold the new content.
_desktop_write_store() {   # <store> <content> -> 0 iff the store now holds exactly <content>
  local store="$1" content="$2" tmp
  tmp="${store}.tracebloc-tmp.$$"
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 1; fi
  if ! mv -f "$tmp" "$store" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 1; fi
  # Byte-for-byte, through cmp: `$(cat ...)` would strip the trailing newline the
  # content deliberately keeps, and read a good write as a bad one.
  printf '%s' "$content" | cmp -s - "$store"
}
# Wait for Docker to answer, bounded on a stock Mac (Bugbot on #1101): the general
# _wait_for_docker probes through _docker_answers, whose bound is `_bounded`, a
# no-op without coreutils -- so a VM that wedges on its new size would block it
# forever, past the restore this path owes the operator. Each probe here runs
# under _bounded_capture (spin's background-pid deadline, coreutils-free), and
# the loop is a wall-clock deadline, not a poll count.
#
# THREE OUTCOMES: 0 Docker answered before <secs> elapsed; 124 it never did and
# the LAST probe hit its deadline (an engine that is up but not answering --
# wedged); 1 it never did and the last probe failed fast (an engine that is down
# or refusing). Both non-zero mean "not back"; the caller's words differ.
# AND ONE NON-OUTCOME (tracebloc-review on #1101): 3 when no temp file could be
# created, so NOTHING was probed. It used to come back as 1, and a caller that
# reads 1 as "down" rolls back a raise nobody measured -- the exact failure the
# tri-state work exists to prevent. Callers word 3 through _desktop_unprobed_words,
# never as a Docker state, and never act on it as one.
_desktop_wait_for_docker() {   # <secs>
  local secs="$1" out deadline rc=1
  out="$(mktemp)" || return 3
  deadline=$(( SECONDS + secs ))
  while (( SECONDS < deadline )); do
    rc=0
    _bounded_capture "${TB_DOCKER_PROBE_TIMEOUT:-10}" "$out" docker info >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then rm -f "$out"; return 0; fi
    sleep 3
  done
  rm -f "$out"
  if (( rc == 124 )); then return 124; fi
  return 1
}
# One bounded "does Docker answer right now" probe, coreutils-free (see above).
# THREE OUTCOMES, passed through as _bounded_capture reports them: 0 it answered;
# 124 the deadline fired (up but not answering); any other status is docker's
# own fast failure (down, or refusing). AND ONE NON-OUTCOME: 3 when no temp file
# could be created, so nothing was probed at all (tracebloc-review on #1101: it
# used to be 2, which the caller rendered as "refused the probe -- it has
# stopped"). The docker CLI reports its own failures as 1 (125-127 for run/exec),
# so 3 cannot be mistaken for its answer.
_desktop_docker_answers() {
  local out rc=0
  out="$(mktemp)" || return 3
  _bounded_capture "${TB_DOCKER_PROBE_TIMEOUT:-10}" "$out" docker info >/dev/null 2>&1 || rc=$?
  rm -f "$out"
  return "$rc"
}
# The one sentence for a probe that never ran (status 3 above), so every arm says
# the same thing and none of them calls it a Docker state. No directory is named:
# macOS's mktemp ignores TMPDIR and picks its own per-user location.
_desktop_unprobed_words() {
  printf 'could not be probed: no temporary file could be created (mktemp failed), so nothing was measured'
}
# The words for the store after a restore attempt, by the restore's OWN status
# (Bugbot on #1101): never "back to N GB" when the write back failed -- Desktop
# would boot on the new, untested size while the operator is told the opposite.
_desktop_restore_words() {   # <restore status> <gb> <store>
  if (( $1 == 0 )); then
    printf 'its settings are back to %s GB' "$2"
  else
    printf 'its settings could NOT be written back to %s GB -- check %s by hand' "$2" "$3"
  fi
}
# The words for a wait that ended in anything but Docker answering, by the wait's
# OWN status (Bugbot on #1101). 124 is an engine that is UP and not answering --
# a wedged VM -- so folding it into "Docker is down" is the wrong diagnosis AND
# the wrong remedy: `open -a Docker` on an app that is already running does
# nothing at all, and the operator follows the sentence into a loop. Two halves,
# both read from the same status, so no arm can word the state one way and the
# remedy the other -- which is exactly how three arms drifted from the two that
# already distinguished 124.
_desktop_wait_words() {   # <wait status> -> what happened
  if (( $1 == 124 )); then
    printf 'is up but not answering'
  else
    printf 'did not come back'
  fi
}
_desktop_wait_remedy() {   # <wait status> -> what to do about it
  if (( $1 == 124 )); then
    printf 'Quit Docker Desktop (force-quit it if the whale menu will not respond) and open it again'
  else
    printf 'Open Docker Desktop'
  fi
}
# The size the RUNTIME reports right now, in display GB, or NOTHING when it did
# not answer (Bugbot on #1101). Every claim in this file about the size a VM is
# running -- Desktop's and Colima's alike, which is why the name says runtime and
# not desktop -- has to come from here: a size that was written, asked for, or
# hoped for is a different fact from the size the VM is running, and the operator
# acts on the second. The grace
# arithmetic is the grading's, so a VM sitting exactly on a rung is not reported
# as short of it. Empty is its own answer, to be said as such rather than filled
# in with the size the installer expected -- that substitution is the bug this
# helper exists to make hard, so callers must branch on it before comparing.
_runtime_probed_gb() {
  local kb; kb="$(_pf_runtime_mem_kb)"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  _pf_display_gb_from_mib "$(( kb / 1024 ))"
}
# Rewrite the store's VM-size key to <mib>: replaced in place when present -- in
# WHICHEVER of the two spellings the store already uses, kept byte for byte --
# inserted under <key> when the store never carried one. Prints nothing; the caller
# reads the file back. Returns 1 when the text has no opening brace to insert
# after, 2 when the key is there in a form this editor will not touch, and 3 when
# BOTH spellings are there and which one Desktop reads is not this script's to
# decide.
_desktop_store_with_memory() {   # <original text> <mib> [key] -> new text on stdout
  # PREFIX + NEW + SUFFIX around the matched text, not `${text/pattern/repl}`: the
  # substitution form re-reads the match as a glob (a `[` in the store is a
  # character class to it), and bash 3.2's quoting inside it is its own trap.
  # `%%"$m"*` / `#*"$m"` take the match literally on every bash this runs on.
  # THE VALUE IS A WHOLE BARE INTEGER, delimiter-anchored: `8192.0` must not match
  # on its integer prefix and come back as `10240.0` (found by the review's own
  # example).
  #
  # AND NOTHING HERE ASKS THE LIBC ABOUT NEWLINES (Bugbot on #1101). The store is
  # multi-line -- that is the shape Desktop writes, and the one the fixture uses --
  # and `.`, `^` and `$` are the three atoms whose meaning against a multi-line
  # subject belongs to regcomp, not to this script: POSIX says `.` spans a newline
  # and the anchors bind the whole string, REG_NEWLINE says the opposite, and the
  # only bash that matters for this file is the stock macOS one, which no CI here
  # can run. A `^(.*"MemoryMiB"…)$` was therefore a claim this repo cannot test.
  # So it is gone: the key and its value are matched with no `.` and no anchor --
  # `[[:space:]]` is a positive bracket expression and matches a newline under
  # either reading -- and the text on both sides is cut off with the same literal
  # `%%`/`#` ops used above, which mean one thing everywhere.
  local text="$1" mib="$2" key="${3:-MemoryMiB}"
  # ONE KEY FAMILY, TWO SPELLINGS (Bugbot on #1101). `MemoryMiB` is what
  # settings-store.json carries; `memoryMiB` is what the older settings.json this
  # path still falls back to carries. The pattern matches either, and because the
  # rebuild below keeps every byte before the value, the spelling the store already
  # uses is the spelling that comes back out -- the editor never renames a key.
  local pat='"[Mm]emoryMiB"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*[,}]' present='"[Mm]emoryMiB"[[:space:]]*:'
  # BOTH SPELLINGS AT ONCE IS NOT A STORE THIS SCRIPT WILL GUESS AT. Two keys of
  # the SAME spelling are last-wins under any JSON parser, which is what the walk
  # below relies on; two DIFFERENT spellings are only resolved by Go's
  # case-insensitive field matching -- a property of Desktop's parser, not of JSON,
  # and not one this repo can test. Desktop never writes such a store, so it means
  # something edited it; refuse before the quit rather than write the wrong one.
  if [[ "$text" =~ \"MemoryMiB\"[[:space:]]*: && "$text" =~ \"memoryMiB\"[[:space:]]*: ]]; then
    return 3
  fi
  if [[ "$text" =~ $pat ]]; then
    # THE LAST match, not the first: two integer memory keys are resolved by Go's
    # encoding/json -- Desktop's parser -- to the LAST one, so editing an
    # earlier one would leave the raise silently undone while every proof passed.
    # The old pattern got that from a greedy `.*`; this walk gets it without one.
    local head="" rest="$text" m=""
    while [[ "$rest" =~ $pat ]]; do
      m="${BASH_REMATCH[0]}"
      head+="${rest%%"$m"*}$m"
      rest="${rest#*"$m"}"
    done
    head="${head%"$m"}"
    # Neither spelling carries a digit of its own, so the match's own digits are the
    # value: everything before the first is the key and its colon, everything after
    # the last is the spacing and the delimiter. Both kept byte for byte.
    printf '%s%s%s%s%s' "$head" "${m%%[0-9]*}" "$mib" "${m##*[0-9]}" "$rest"
  elif [[ "$text" =~ $present ]]; then
    # PRESENT, IN A FORM THIS EDITOR DOES NOT READ (tracebloc-review on #1101):
    # `null`, a float, or the managed-settings object `{"value": …, "locked": true}`.
    # Inserting a second key here would leave a duplicate; Go's encoding/json --
    # Desktop's parser -- keeps the LAST one, so the raise would silently not
    # happen while every proof passed. Refuse instead, with its own status.
    return 2
  else
    # Same rule as above, and these two were members of the same class: `^…\{` and
    # `^…\}` against a multi-line store are anchors whose reading decides whether
    # the opening brace is the FIRST one or any line's, and whether `{…}` with keys
    # in it counts as empty and so takes no trailing comma -- a wrong comma is
    # invalid JSON, which Desktop then refuses to read at all. Cut literally
    # instead: the brace is the first `{` in the text, and it is the opening brace
    # only if nothing but whitespace precedes it.
    local m="${text%%\{*}"
    [[ "$m" != "$text" && -z "${m//[[:space:]]/}" ]] || return 1
    m="${m}{"
    local rest="${text#"$m"}" comma=","
    # `{}`: a first key takes no trailing comma. The store's first non-space byte
    # after the brace, found by cutting its leading whitespace off rather than by
    # anchoring a pattern to it.
    [[ "${rest#"${rest%%[![:space:]]*}"}" == "}"* ]] && comma=""
    # THE SPELLING COMES FROM THE CALLER, which read it off the store (Bugbot on
    # #1101). Hard-coding `MemoryMiB` here is what put a key an older Desktop does
    # not read into an older Desktop's settings.json, after quitting it.
    printf '%s\n  %s%s%s' "$m" "\"${key}\": ${mib}" "$comma" "$rest"
  fi
}
_offer_desktop_memory_raise() {
  [[ "${OS:-$(uname -s)}" == "Darwin" ]] || return 0
  has docker || return 0
  _docker_app_installed || return 0
  # The measured budget must belong to the runtime we are about to restart -- and
  # "could not tell" is said, not skipped past (bounded-reads-propagate.bats).
  local active=0
  _desktop_is_active_runtime || active=$?
  case "$active" in
    0) ;;
    2) hint "Docker did not answer within ${TB_DOCKER_PROBE_TIMEOUT:-10}s, so the installer cannot tell whether Docker Desktop is the runtime it would raise. If it is, raise it yourself: Docker Desktop → Settings → Resources → Memory."
       return 0 ;;
    # 3 IS NOT 2: nothing was probed, so no timeout can be quoted (Bugbot on
    # #1101). Still said rather than skipped in silence -- the offer is declined
    # either way, and the operator is told which of the two it was.
    3) hint "Whether Docker Desktop is the runtime the installer would raise $(_desktop_unprobed_words). If it is, raise it yourself: Docker Desktop → Settings → Resources → Memory."
       return 0 ;;
    *) return 0 ;;
  esac

  local current_kb current_mib target_gb current_gb rung_eff short_reason
  current_kb="$(_pf_runtime_mem_kb)"
  [[ "$current_kb" =~ ^[0-9]+$ && "$current_kb" -gt 0 ]] || return 0
  current_mib=$(( current_kb / 1024 ))
  # Graded in MiB with the guest-MemTotal grace, exactly as the Colima path and
  # _pf_runtime_mem_status grade it -- a Desktop VM set to the documented floor
  # reports a few hundred MiB less and must not be "fixed".
  current_gb="$(_pf_display_gb_from_mib "$current_mib")"
  target_gb="$(_macos_vm_mem_gb)"
  [[ "$target_gb" =~ ^[0-9]+$ && "$target_gb" -gt 0 ]] || return 0
  rung_eff="$(_pf_clamp_mem_gb "$PF_WARN_MEM_GB")"
  if (( current_mib < PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB )); then
    short_reason="floor"
  elif [[ "$rung_eff" =~ ^[0-9]+$ ]] && (( current_mib < rung_eff * 1024 - PF_VM_MEM_GRACE_MIB )); then
    short_reason="rung"
  else
    return 0
  fi
  # The two honest non-offers, in the Colima path's words: a Mac that cannot reach
  # the floor, and a rung raise the host cannot honour.
  if [[ "$short_reason" == "floor" ]] && (( target_gb < PF_MIN_MEM_GB )); then
    hint "This Mac cannot spare ${PF_MIN_MEM_GB} GB for Docker (the most it can give is ${target_gb} GB), so raising the VM would not fix it. Training needs a larger machine."
    return 0
  fi
  if [[ "$short_reason" == "rung" ]] && (( target_gb < PF_WARN_MEM_GB )); then
    hint "This Mac cannot give Docker the ${PF_WARN_MEM_GB} GB the smallest training run (4 GiB) needs beside the platform (the most it can spare is ${target_gb} GB), so the VM is left as it is. It runs the client; train on a larger machine."
    return 0
  fi

  local store text manual
  manual="Docker Desktop → Settings → Resources → Memory → ${target_gb} GB, then Apply & restart"
  if ! store="$(_desktop_settings_store)"; then
    hint "Docker Desktop's settings store was not found under ~/Library/Group Containers/group.com.docker, so the VM is left at ${current_gb} GB. Raise it yourself: ${manual}."
    return 0
  fi
  if ! text="$(cat "$store" 2>/dev/null)" || [[ -z "$text" ]]; then
    hint "Docker Desktop's settings store at ${store} could not be read, so the VM is left at ${current_gb} GB. Raise it yourself: ${manual}."
    return 0
  fi

  if [[ "$short_reason" == "rung" ]]; then
    warn "Docker Desktop's VM has ${current_gb} GB — enough to run the client, but the smallest training run (4 GiB) needs a ${PF_WARN_MEM_GB} GB budget once the kubelet reservation, k3s addons, control plane and CronJobs are counted; training pods would stay Pending."
  else
    warn "Docker Desktop's VM has ${current_gb} GB — below the ${PF_MIN_MEM_GB} GB tracebloc needs to train."
  fi

  # CONSENT, exactly as the Colima raise takes it: no TTY -> the instruction; a
  # bare Enter declines; TRACEBLOC_ASSUME_YES=1 takes a FLOOR raise unattended (the
  # VM would OOM anyway) and never a RUNG raise -- that stops a working runtime,
  # with every container in it, for capacity nobody asked about (tracebloc-review
  # on client#1090). Desktop has no size pin to name as consent, so unattended the
  # rung raise is only ever the instruction.
  if [[ "${TRACEBLOC_ASSUME_YES:-}" != "1" ]]; then
    if ! _tty_usable; then
      hint "Raise it: ${manual}."
      return 0
    fi
    local reply=""
    prompt_header "Raise Docker Desktop's VM to ${target_gb} GB now?"
    hint "This QUITS Docker Desktop — every running container goes down — writes the new size into its settings, and relaunches it."
    _read_sanitized "  Raise it? [y/N] " reply
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) ;;
      *) hint "Left alone. Raise it later: ${manual}."; return 0 ;;
    esac
  elif [[ "$short_reason" == "rung" ]]; then
    hint "Not raised unattended: Docker Desktop is running, and the raise quits it with every container in it. Raise it yourself: ${manual}."
    return 0
  fi

  local new_text mib mem_key
  mib=$(( target_gb * 1024 ))
  # WHICH KEY THIS STORE USES, read off the store itself (Bugbot on #1101). It is
  # both what an inserted key is named and what every by-hand instruction below
  # quotes; the re-read after the quit recomputes it, because the flush Desktop
  # does on its way down is allowed to change the file.
  mem_key="$(_desktop_memory_key "$text" "$store")"
  # A SHAPE PROBE BEFORE THE QUIT, on the text read above: a store this installer
  # cannot edit must never cost the operator a Desktop restart. The edit itself is
  # made below, on the store as it stands AFTER the quit.
  local shape=0
  _desktop_store_with_memory "$text" "$mib" "$mem_key" >/dev/null || shape=$?
  if (( shape == 2 )); then
    hint "Docker Desktop's settings store at ${store} carries ${mem_key} in a form this installer does not edit (a managed or non-numeric value), so the VM is left at ${current_gb} GB. Raise it yourself: ${manual}."
    return 0
  elif (( shape == 3 )); then
    hint "Docker Desktop's settings store at ${store} carries both MemoryMiB and memoryMiB, and which one Docker Desktop reads depends on its version, so this installer will not pick one; the VM is left at ${current_gb} GB. Remove the spelling your Docker Desktop does not use, or raise it yourself: ${manual}."
    return 0
  elif (( shape != 0 )); then
    hint "Docker Desktop's settings store at ${store} is not the JSON object this installer knows how to edit, so the VM is left at ${current_gb} GB. Raise it yourself: ${manual}."
    return 0
  fi

  # ONE BUDGET FOR EVERY "wait for Desktop to come back" BELOW, and every message
  # reads it instead of a literal (Bugbot on #1101). 180 s was shorter than the
  # Desktop start this same file already budgets: the GUI start hands
  # `_wait_for_docker` 80 polls x 3 s = 240 s, and 120 x 3 = 360 s on a first
  # launch -- and Colima's matching start is bounded at 900 s. So a Desktop
  # still coming up, on a LARGER VM than the one that was measured at that, was
  # declared not-back and the raise rolled back underneath it. Take the
  # first-launch figure: a relaunch that has to boot a resized VM is the slow
  # case, not the warm one. Overridable for a Mac slower still, like the probe
  # timeout beside it.
  local wait_secs="${TB_DESKTOP_RESTART_WAIT:-360}"

  # QUIT FIRST, THEN WRITE. Bounded: a Desktop that does not quit is left exactly
  # as it was, and said so -- never killed (see _desktop_quit_and_wait).
  if ! spin_cmd_bounded 90 "Quitting Docker Desktop…" _desktop_quit_and_wait 30; then
    # "LEFT AS IT WAS" HAS TO BE CHECKED, NOT ASSUMED (Bugbot on #1101, the same
    # lesson the Colima path's stop-failure branch records): the quit WAS sent, so
    # a Desktop still on the process list may be halfway down. If Docker still
    # answers, nothing changed and the instruction stands; if it does not, this
    # path relaunches what it started to stop and refuses to continue on a dying
    # runtime -- every later step needs Docker.
    local answers=0
    _desktop_docker_answers || answers=$?
    case "$answers" in
      0)   warn "Docker Desktop did not quit within 60 s but Docker still answers; the VM is left at ${current_gb} GB. Raise it yourself: ${manual}."
           return 0 ;;
      124) warn "Docker Desktop did not finish quitting within 60 s and Docker is not answering within ${TB_DOCKER_PROBE_TIMEOUT:-10}s (shutting down, or wedged); relaunching it unchanged." ;;
      3)   warn "Docker Desktop did not finish quitting within 60 s and whether Docker still answers $(_desktop_unprobed_words); relaunching it unchanged." ;;
      *)   warn "Docker Desktop did not finish quitting within 60 s and Docker refused the probe (exit ${answers}) -- it has stopped; relaunching it unchanged." ;;
    esac
    open -a Docker 2>/dev/null || true
    local back=0
    _desktop_wait_for_docker "$wait_secs" || back=$?
    if (( back == 0 )); then
      warn "Docker is back at ${current_gb} GB. Raise it yourself: ${manual}."
      return 0
    elif (( back == 3 )); then
      error "Docker Desktop did not finish quitting, and whether it came back $(_desktop_unprobed_words); its settings are unchanged (${current_gb} GB). Open Docker Desktop, then re-run the installer."
    else
      error "Docker Desktop did not finish quitting and $(_desktop_wait_words "$back"); its settings are unchanged (${current_gb} GB). $(_desktop_wait_remedy "$back"), then re-run the installer."
    fi
  fi
  # RE-READ AFTER THE QUIT, THEN EDIT (Bugbot on #1101): the graceful quit exists
  # to let Desktop flush its in-memory state to this file, so an edit made on the
  # pre-quit snapshot would put that snapshot back and lose whatever the flush
  # wrote. The text edited, written and -- on every restore path below -- restored
  # is the store as it stands now, with Desktop down. A store that cannot be read
  # or edited any more relaunches Desktop untouched: nothing has been written yet.
  if ! text="$(cat "$store" 2>/dev/null)" || [[ -z "$text" ]] ||
     ! mem_key="$(_desktop_memory_key "$text" "$store")" ||
     ! new_text="$(_desktop_store_with_memory "$text" "$mib" "$mem_key")"; then
    hint "Docker Desktop's settings store at ${store} could not be re-read or edited after Desktop quit, so it is left as Desktop wrote it and Desktop is being relaunched unchanged. Raise it yourself: ${manual}."
    open -a Docker 2>/dev/null || error "Docker Desktop could not be relaunched (open -a Docker failed); its settings are as it left them. Open Docker Desktop, then re-run the installer."
    local back=0
    _desktop_wait_for_docker "$wait_secs" || back=$?
    if (( back == 3 )); then
      error "Whether Docker Desktop came back after being quit $(_desktop_unprobed_words); its settings are as it left them. Open Docker Desktop, then re-run the installer."
    elif (( back != 0 )); then
      error "Docker Desktop $(_desktop_wait_words "$back") within ${wait_secs} s after being quit; its settings are as it left them. $(_desktop_wait_remedy "$back"), then re-run the installer."
    fi
    return 0
  fi
  # Keep the trailing newline the file had (`$(...)` strips it), and PROVE the write:
  # every write below is a condition, never a bare statement (see _desktop_write_store).
  local trailing=""
  [[ "$(tail -c 1 "$store" 2>/dev/null | od -An -c | tr -d ' ')" == '\n' ]] && trailing=$'\n'
  # THE READ-BACK ACCEPTS EXACTLY THE SPACING THE EDITOR DOES (tracebloc-review on
  # #1101): the editor keeps a space before the colon, and a read-back that did
  # not rolled a working edit back -- after Desktop had been quit.
  # AND IT LOOKS FOR THE KEY THAT WAS ACTUALLY WRITTEN, not for `MemoryMiB`
  # (Bugbot on #1101): on an older settings.json the editor keeps `memoryMiB`, and
  # a read-back that only knew the PascalCase name would roll a correct edit
  # back -- after Desktop had been quit.
  if ! _desktop_write_store "$store" "${new_text}${trailing}" || ! grep -qE '"'"${mem_key}"'"[[:space:]]*:[[:space:]]*'"${mib}"'[[:space:]]*([,}]|$)' "$store"; then
    local restored=0
    _desktop_write_store "$store" "${text}${trailing}" || restored=$?
    if (( restored == 0 )); then
      warn "The new size did not read back from ${store}; the previous settings were restored and Docker Desktop is being relaunched unchanged. Raise it yourself: ${manual}."
    else
      warn "The new size did not read back from ${store}, and the previous settings could not be written back either -- check the file by hand. Docker Desktop is being relaunched on whatever it holds."
    fi
    # AND THE RELAUNCH IS CHECKED (Bugbot on #1101): Desktop was quit by this path,
    # so a Desktop that does not come back is Docker down for every later step --
    # the same hard failure the other two arms raise, never a `return 0` that lets
    # the GUI path print "Docker ready".
    open -a Docker 2>/dev/null || error "Docker Desktop could not be relaunched (open -a Docker failed) after a settings write that did not read back; $(_desktop_restore_words "$restored" "$current_gb" "$store"). Open Docker Desktop, then re-run the installer."
    local back=0
    _desktop_wait_for_docker "$wait_secs" || back=$?
    if (( back == 3 )); then
      error "Whether Docker Desktop came back after a settings write that did not read back $(_desktop_unprobed_words); $(_desktop_restore_words "$restored" "$current_gb" "$store"). Open Docker Desktop, then re-run the installer."
    elif (( back != 0 )); then
      error "Docker Desktop $(_desktop_wait_words "$back") within ${wait_secs} s after a settings write that did not read back; $(_desktop_restore_words "$restored" "$current_gb" "$store"). $(_desktop_wait_remedy "$back"), then re-run the installer."
    fi
    return 0
  fi
  if ! open -a Docker 2>/dev/null; then
    # THE RESTORE IS WORDED BY ITS OWN STATUS (tracebloc-review on #1101): a `|| true`
    # here told the operator "restored" while Desktop would boot on the new size.
    if _desktop_write_store "$store" "${text}${trailing}"; then
      error "Docker Desktop could not be relaunched after the memory change (open -a Docker failed); its settings were restored (${current_gb} GB). Open Docker Desktop, then re-run the installer."
    else
      error "Docker Desktop could not be relaunched after the memory change (open -a Docker failed), and the previous settings could not be written back to ${store} either -- it holds ${target_gb} GB. Check the file by hand, open Docker Desktop, then re-run the installer."
    fi
  fi
  local back=0
  _desktop_wait_for_docker "$wait_secs" || back=$?
  if (( back == 3 )); then
    # NOTHING WAS MEASURED, SO NOTHING IS ROLLED BACK (tracebloc-review on #1101):
    # the recovery below undoes a raise Docker did not answer. A raise nobody could
    # ask about is left standing and said so, with the way back spelled out.
    error "Whether Docker Desktop came back with ${target_gb} GB $(_desktop_unprobed_words). Its settings now hold ${target_gb} GB (they were ${current_gb} GB); if Docker does not come up, set ${mem_key} back in ${store}. Open Docker Desktop, then re-run the installer."
  elif (( back != 0 )); then
    # WE STOPPED IT, SO WE OWN GETTING IT BACK: restore the size that was working
    # a moment ago and relaunch on it, the way the Colima path restores its VM.
    warn "Docker Desktop $(_desktop_wait_words "$back") within ${wait_secs} s with ${target_gb} GB; restoring the previous size."
    # QUIT FIRST, THEN RESTORE (Bugbot on #1101): the order this whole path exists
    # to enforce holds on the way back too -- a wedged Desktop still running can
    # flush its in-memory size over a restore written under it, and the recovery
    # would relaunch the size that just failed while saying the old one is back.
    # Bounded like the forward quit (Bugbot on #1101): this is the wedged-VM arm,
    # and a bare `osascript quit` waits on the Apple Event a wedged Desktop may
    # never answer -- the restore below has to run whatever Desktop does.
    spin_cmd_bounded 90 "Quitting Docker Desktop…" _desktop_quit_and_wait 30 || true
    local restored=0
    _desktop_write_store "$store" "${text}${trailing}" || restored=$?
    (( restored == 0 )) || warn "The previous settings could not be written back to ${store}; check the file by hand."
    open -a Docker 2>/dev/null || true
    local back2=0
    _desktop_wait_for_docker "$wait_secs" || back2=$?
    if (( back2 == 0 )); then
      if (( restored != 0 )); then
        warn "Docker is back, but on whatever ${store} holds: the restore to ${current_gb} GB could not be written. Check the file by hand."
        return 0
      fi
      # RE-PROBED, NOT READ OFF THE WRITE (Bugbot on #1101): the recovery quit
      # above is `|| true` on purpose -- this is the wedged-VM arm, and a Desktop
      # that never answers the Apple Event must not stop the restore. But a quit
      # that did not take leaves Desktop UP on the size it booted with; it can
      # flush that back over the file, `open -a Docker` on a running app does
      # nothing, and the wait then succeeds because Docker never went away. A
      # successful restore write is therefore not evidence of the running size --
      # the happy path below re-probes before it claims one, and so does this.
      local now_gb; now_gb="$(_runtime_probed_gb)"
      if [[ -z "$now_gb" ]]; then
        warn "Docker is back and ${store} was written back to ${current_gb} GB, but Docker did not answer when asked what its VM has, so the running size was not measured. Check Settings → Resources; raise it yourself when the machine can spare it: ${manual}."
      elif (( now_gb > current_gb )); then
        warn "Docker is back on ${now_gb} GB, not the ${current_gb} GB written back to ${store}: Docker Desktop did not quit for the restore and has kept the size it was already running. Quit Docker Desktop (force-quit it if the whale menu will not respond) and open it again; if it still reports ${now_gb} GB, set ${mem_key} back in ${store} by hand."
      else
        warn "Docker is back at ${now_gb} GB. Raise it yourself when the machine can spare it: ${manual}."
      fi
      return 0
    elif (( back2 == 3 )); then
      error "Whether Docker Desktop restarted after the memory change $(_desktop_unprobed_words). $(_desktop_restore_words "$restored" "$current_gb" "$store"); open Docker Desktop, then re-run the installer."
    else
      error "Docker Desktop $(_desktop_wait_words "$back2") within ${wait_secs} s after the memory change ($(_desktop_restore_words "$restored" "$current_gb" "$store")). $(_desktop_wait_remedy "$back2"), then re-run the installer."
    fi
  fi

  # RE-PROBED, not assumed: a relaunch that succeeded and a VM that grew are two facts.
  # AND A PROBE THAT DID NOT ANSWER IS NEITHER (same class as the recovery arm
  # above, Bugbot on #1101): the `else` here used to print "still reports
  # ${current_gb} GB" for both a VM that measurably did not grow AND a Docker that
  # said nothing at all -- one sentence asserting a size nobody read. They are
  # separated now, and the measured arm prints the number it measured.
  local new_gb; new_gb="$(_runtime_probed_gb)"
  if [[ -z "$new_gb" ]]; then
    warn "Docker Desktop relaunched, but Docker did not answer when asked what its VM has, so the new size was not measured. Check Settings → Resources: ${manual}."
  elif (( new_gb > current_gb )); then
    success "Docker Desktop's VM raised to ${new_gb} GB."
  else
    warn "Docker Desktop relaunched but still reports ${new_gb} GB. Check Settings → Resources and raise it yourself: ${manual}."
  fi
  return 0
}

# Verify a downloaded Docker.dmg against Docker's published checksums.txt.
# FAIL CLOSED (#629): aborts on a checksum mismatch AND on an unfetchable
# checksum — matching kubectl / k3d / helm, which also fetch their checksum over
# the network and abort on an empty hash (setup-linux.sh, via `_verify_sha256`).
# The DMG is about to be mounted and copied into /Applications under sudo, so an
# unverifiable download must not be installed. A user knowingly behind a
# checksum-stripping proxy can opt out with TRACEBLOC_ALLOW_UNVERIFIED_DOCKER_DMG=1.
_verify_docker_dmg() {
  local dmg_path="$1" checksum_url="$2"
  local expected_hash="" _attempt
  # Fetch the published checksum, retrying transient failures. Capture cleanly
  # (not through the generic retry(), whose progress notes go to stdout and would
  # pollute the captured hash). Pick the Docker.dmg line; field 1 is the hash. The
  # ``$1 ~ /^[0-9a-fA-F]{64}$/`` guard also rejects a TLS-inspecting proxy's HTML
  # error body that merely mentions "Docker.dmg": a non-hash field 1 leaves
  # ``expected_hash`` empty, so it takes the fail-closed path below.
  for _attempt in 1 2 3; do
    expected_hash=$(curl_secure -fsSL "$checksum_url" 2>/dev/null \
      | awk '$1 ~ /^[0-9a-fA-F]{64}$/ && /Docker\.dmg/{print $1; exit}') || true
    [[ -n "$expected_hash" ]] && break
    [[ "$_attempt" -lt 3 ]] && sleep 5
  done

  if [[ -n "$expected_hash" ]]; then
    # Checksum available (the clean-network path): verify and FAIL CLOSED on a
    # mismatch (#556).
    local actual_hash
    actual_hash=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      rm -f "$dmg_path"
      error "Docker Desktop DMG checksum mismatch — download may be corrupted or tampered with"
    fi
    log "Docker Desktop checksum verified."
    return 0
  fi

  # No checksum could be fetched. On a clean network checksums.txt is always
  # present, so this is an anomalous path — a TLS-inspecting proxy stripping it,
  # a transient CDN error, or Docker changing its layout. FAIL CLOSED by default
  # (#629), consistent with the other pinned tools; opt out only if you know why.
  if [[ -z "${TRACEBLOC_ALLOW_UNVERIFIED_DOCKER_DMG:-}" ]]; then
    rm -f "$dmg_path"
    error "Could not fetch the Docker Desktop checksum from ${checksum_url} — refusing to install an unverified DMG. A proxy/VPN may be rewriting traffic to desktop.docker.com; fix egress and re-run, or set TRACEBLOC_ALLOW_UNVERIFIED_DOCKER_DMG=1 to install unverified at your own risk."
  fi
  warn "Installing Docker Desktop UNVERIFIED — could not fetch its checksum from ${checksum_url} and TRACEBLOC_ALLOW_UNVERIFIED_DOCKER_DMG is set."
}

install_docker_desktop() {

  # On headless Macs (EC2, CI runners), Docker Desktop can't launch.
  # If Docker is already running (e.g. started via VNC earlier), skip detection.
  if ! _has_gui_session && ! _docker_answers_bounded "Checking Docker…" "${TB_DOCKER_PROBE_TIMEOUT:-10}"; then
    _install_docker_colima
    # AFTER the runtime is up, so `docker info` can be read (backend#2221). A
    # fresh VM is already sized from physical RAM (#428) and this is a no-op on
    # it; an EXISTING under-sized VM is the case that had nothing but a warning.
    _offer_colima_memory_raise
    _offer_desktop_memory_raise
    return
  fi
  # The already-running case: on a headless Mac whose Colima VM was started
  # earlier (VNC, a previous install) the branch above is skipped entirely, so
  # the offer has to be made here too or the exact machine that needs it -- one
  # with an old, small VM -- never sees it.
  if ! _has_gui_session; then
    _offer_colima_memory_raise
    _offer_desktop_memory_raise
    # RETURN, so a headless Colima machine never falls through into the Docker
    # Desktop arch-detection below (Cursor Bugbot, twice). Docker is already up on
    # this path -- that is the condition that got us here -- so there is nothing
    # for the Desktop branch to do except produce a Desktop error on a machine
    # that runs Colima.
    return
  fi

  # Detect real hardware — sysctl is immune to Rosetta translation
  # Capture-then-match (#680): inside an `if`, a SIGPIPE'd producer under
  # pipefail reads as "no match" and takes the WRONG branch — here that would
  # call an Apple Silicon Mac amd64 and fetch the Intel Docker Desktop DMG.
  local real_arch _arm64_flag
  _arm64_flag="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
  if [[ "$_arm64_flag" == "1" ]]; then
    real_arch="arm64"
  else
    real_arch="amd64"
  fi

  local fresh_install=false
  local need_install=false

  # Check if existing Docker Desktop is for the wrong architecture (either direction)
  # Main executable is com.docker.backend (CFBundleExecutable), not "Docker"
  if [[ -d "/Applications/Docker.app" ]]; then
    local docker_bin_path="/Applications/Docker.app/Contents/MacOS/com.docker.backend"
    [[ ! -x "$docker_bin_path" ]] && docker_bin_path="/Applications/Docker.app/Contents/MacOS/Docker"
    local docker_bin_arch
    docker_bin_arch="$(file "$docker_bin_path" 2>/dev/null || true)"
    local docker_is_arm=false
    local docker_is_intel=false
    # `case`, not `echo … | grep -q && var=true` (#680): drops both pipes and the
    # `A && B` form, whose non-zero status when the arch does NOT match is a
    # set -e subtlety this file should not depend on.
    case "$docker_bin_arch" in *arm64*)  docker_is_arm=true   ;; esac
    case "$docker_bin_arch" in *x86_64*) docker_is_intel=true ;; esac

    local wrong_arch=false
    if [[ "$real_arch" == "arm64" ]] && [[ "$docker_is_intel" == true ]] && [[ "$docker_is_arm" != true ]]; then
      wrong_arch=true
    fi
    if [[ "$real_arch" == "amd64" ]] && [[ "$docker_is_arm" == true ]]; then
      wrong_arch=true
    fi

    if [[ "$wrong_arch" == true ]]; then
      echo ""
      if [[ "$real_arch" == "arm64" ]]; then
        warn "Docker is installed for the wrong chip (Intel instead of Apple Silicon)."
        hint "This can cause slow performance or prevent Docker from starting."
      else
        warn "Docker is installed for the wrong chip (Apple Silicon instead of Intel)."
        hint "Docker may not work correctly."
      fi
      echo -e "  ${BOLD}We'll replace it with the correct version for your Mac.${RESET}"
      echo ""

      if [[ "${TRACEBLOC_DOCKER_ARCH_PROMPT:-0}" == "1" ]]; then
        # Read the terminal, not the (EOF) `curl … | bash` install pipe — otherwise
        # `reply` is always empty and the confirmation below is meaningless (the
        # replacement proceeds without a real answer). No tty => empty => proceed,
        # preserving the opt-in prompt's prior non-interactive behavior.
        local reply=""
        if [[ -r /dev/tty ]]; then read -r -p "  Replace wrong-architecture Docker with native version? [Y/n] " reply </dev/tty || reply=""; fi
        if [[ -n "$reply" && "$reply" != "y" && "$reply" != "Y" ]]; then
          echo ""
          echo -e "  ${BOLD}Skipped.${RESET} To fix later, re-run this installer."
          echo ""
          error "Docker version mismatch. Install the correct version and re-run."
        fi
      fi

      log "Quitting and removing wrong-architecture Docker Desktop…"
      osascript -e 'quit app "Docker"' 2>/dev/null || true
      sleep 2
      pkill -x "Docker Desktop" 2>/dev/null || true; sleep 1
      pkill -9 -x "Docker Desktop" 2>/dev/null || true; sleep 1
      # sudo required: Docker.app contains protected paths (LoginItems, provisionprofile, etc.)
      # Official uninstall script is not used here — it can block when run non-interactively.
      sudo rm -rf /Applications/Docker.app
      need_install=true
      fresh_install=true
      success "Removed. Installing correct Docker version."
    fi
  fi

  if ! has docker || [[ "$need_install" == true ]]; then
    fresh_install=true

    log "Detected hardware architecture: $real_arch"

    local dmg_url="https://desktop.docker.com/mac/main/${real_arch}/Docker.dmg"
    local dmg_path="/tmp/Docker.dmg"

    log "Downloading Docker Desktop DMG for $real_arch"
    # Real %-by-bytes bar: this is a single-file curl of the .dmg, so the byte
    # percentage is genuine (download_with_progress) — not a fabricated aggregate.
    retry 3 5 download_with_progress "$dmg_url" "$dmg_path" \
      "Downloading Docker Desktop — large, a few minutes on a fresh Mac"

    # Docker publishes the checksum for this floating DMG in a co-located
    # "checksums.txt" (BSD format: "<sha256> *Docker.dmg"). Verify against it,
    # failing closed on a mismatch OR an unfetchable checksum (see
    # _verify_docker_dmg) — the DMG is about to be mounted and copied into
    # /Applications under sudo.
    _verify_docker_dmg "$dmg_path" "${dmg_url%/*}/checksums.txt"

    # #561: bounded so hdiutil on a bad/corrupt DMG can't hang forever.
    spin_cmd_bounded 900 "Installing Docker Desktop…" bash -c \
      "hdiutil attach '$dmg_path' -nobrowse -quiet && \
       cp -R '/Volumes/Docker/Docker.app' /Applications/ && \
       xattr -cr /Applications/Docker.app && \
       hdiutil detach '/Volumes/Docker' -quiet 2>/dev/null; \
       rm -f '$dmg_path'"

    log "Docker Desktop ($real_arch) installed to /Applications."
  fi

  _kill_lingering_docker

  # ── Make sure Docker Desktop is running ──────────────────────────────────
  if ! _docker_answers; then
    open -a Docker

    if [[ "$fresh_install" == true ]]; then
      echo ""
      echo -e "  ${BOLD}Docker Desktop is starting for the first time.${RESET}"
      echo -e "  Please do the following in the Docker window that just opened:"
      echo ""
      echo -e "    ${CYAN}Approve the privileged-helper prompt${RESET} — macOS asks for your admin password once"
      echo -e "    ${CYAN}Accept the license agreement${RESET} when prompted"
      echo ""
      echo -e "  ${BOLD}The installer will continue automatically once Docker is ready.${RESET}"
      echo ""
    else
      log "Starting Docker Desktop…"
    fi

    local max_wait=80
    if [[ "$fresh_install" == true ]]; then max_wait=120; fi
    # `|| true` is load-bearing. _wait_for_docker returns non-zero on timeout,
    # and this is a bare statement under `set -e`, so the script would exit HERE
    # — before the whale-icon guidance and the deliberate error() below, which
    # is the whole point of not coming up in time. The old inline loop ended on
    # printf/tput and so always fell through; extracting it moved the timeout's
    # exit status into a position where errexit could see it (Bugbot, #741).
    # The verdict is the `if ! _docker_answers` immediately below, not this.
    _wait_for_docker "$max_wait" || true
  fi

  if ! _docker_answers; then
    echo ""
    echo -e "  ${BOLD}Docker Desktop isn't responding yet.${RESET}"
    echo -e "  This usually means it's still starting up. Here's what to check:"
    echo ""
    echo -e "    1. Look for the ${CYAN}whale icon 🐳${RESET} in your menu bar"
    echo -e "    2. If Docker is open, wait until it says ${CYAN}\"Docker Desktop is running\"${RESET}"
    echo -e "    3. ${CYAN}Re-run this script${RESET} once it's ready"
    echo ""
    echo -e "  ${BOLD}Nothing is broken — Docker just needs a moment.${RESET}"
    echo ""
    error "Docker Desktop did not start in time. Re-run this script once Docker is ready."
  fi

  # THE OFFER BELONGS HERE TOO (Bugbot on #1101): a Mac whose Desktop was installed
  # but stopped -- autostart off, the common case -- reaches this path, not Tier 0,
  # and used to be told "Docker ready" with a VM the smallest run cannot use.
  _offer_desktop_memory_raise
  success "Docker ready"
}

# _wait_for_docker POLLS — spin until the daemon answers, or POLLS*3s elapse.
# Returns 0 as soon as the daemon answers, 1 on timeout.
#
# Extracted so the assess-time nudge (_try_start_docker_desktop) and the
# install-time start share ONE loop. Two copies of a "wait for Docker" loop
# drift, and the one nobody reads is the one that stops matching the daemon's
# actual readiness.
_wait_for_docker() {
  local polls="$1" f=0 elapsed
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  # A WALL-CLOCK deadline, not a poll count. Each probe is itself bounded, so a
  # wedged daemon burns TB_DOCKER_PROBE_TIMEOUT per attempt; counting iterations
  # would let "20 polls" mean 60s against a live daemon and 260s against the
  # wedged one this exists to survive. $SECONDS keeps the caller's budget —
  # polls*3s — true either way.
  local start=$SECONDS
  local deadline=$(( SECONDS + polls * 3 ))
  tput civis 2>/dev/null || true
  while [ "$SECONDS" -lt "$deadline" ]; do
    if _docker_answers; then
      printf "\r\033[K"
      tput cnorm 2>/dev/null || true
      return 0
    fi
    elapsed=$(( SECONDS - start ))
    printf "\r  ${CYAN}%s${RESET} Waiting for Docker Desktop… (%ds)" "${frames[f]}" "$elapsed"
    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 3
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true
  _docker_answers
}

# _docker_app_installed — is Docker Desktop present as an app bundle?
#
# Its own function purely so the branch above is testable on any host: inlined,
# the "not installed" case could only be exercised on a machine WITHOUT Docker,
# which is never the machine of the person changing this code.
_docker_app_installed() {
  [[ -d /Applications/Docker.app || -d "$HOME/Applications/Docker.app" ]]
}

# _try_start_docker_desktop — best-effort nudge for a Docker Desktop that is
# INSTALLED but not running. Returns 0 if a runtime is usable afterwards.
#
# This exists because of the trap in client#703's neighbourhood: a stopped
# Docker means PROBE_RUNTIME_USABLE=0, which on macOS means Tier 2, which runs
# the admin gate and preflight_sudo — and the ONLY `open -a Docker` in the tree
# lived inside install_docker_desktop, behind that password prompt. So the
# installer could only start Docker after taking an administrator password that
# it needed solely because Docker wasn't started. A user who can't give that
# password had no path at all, on a Mac where Docker was already installed.
#
# `open -a Docker` needs no privileges whatsoever — it is a GUI app launch as
# the current user. Doing it here, before classification, lets the probe find a
# live runtime and hand the machine to Tier 0, where none of the privileged
# path runs.
#
# Best-effort by construction: every failure returns non-zero and the caller
# says so honestly. It must never become a hard gate — a Mac with no Docker
# installed still has to reach install_docker_desktop.
_try_start_docker_desktop() {
  [[ "${OS:-}" == "Darwin" ]] || return 1
  has docker || return 1
  # Already up — nothing to nudge (and the caller shouldn't claim it started it).
  _docker_answers && return 0
  # Only nudge an app that is actually installed; otherwise this is a job for
  # install_docker_desktop, which downloads it.
  _docker_app_installed || return 1
  log "runtime-down: nudging Docker Desktop (open -a Docker, no privileges needed)"
  open -a Docker 2>/dev/null || { log "runtime-down: open -a Docker failed"; return 1; }
  # 20 polls x 3s = 60s. An already-installed Docker Desktop that has been run
  # before is warm; this is a nudge, not the 120s first-run licence dance.
  _wait_for_docker 20
}

install_macos_cli_tools() {
  # kubectl/k3d/helm now come from the SAME pinned, checksum-verified direct-download
  # path as Linux — install_kubectl / install_k3d / install_helm (setup-linux.sh, always
  # sourced) are OS-aware via OS_DL, so the K3D_VERSION / HELM_VERSION pins are honored
  # on macOS instead of brew floating to latest and diverging from the chart-tested
  # Linux installs (#429). brew still delivers Docker/colima (install_docker_desktop) —
  # this only moves the version-pinned CLI tools onto the shared path. Each installer
  # ends in the execute-gate (#411, assert_tool_runs), so a broken/wrong-arch binary
  # fails the "System tools" step loudly rather than printing a false success.
  OS_DL="darwin"
  # Tier 0 (client#703): a usable runtime already exists and this run holds NO
  # sudo credential — writing to /usr/local/bin would prompt for a password to do
  # the one thing Tier 0 exists to avoid. Land the pinned binaries in
  # ~/.local/bin instead, the same no-sudo target install_linux's
  # _set_tools_target picks, and put it on this shell's PATH.
  #
  # Every other tier keeps /usr/local/bin, which is on the default login PATH
  # (/etc/paths) on BOTH Intel and Apple Silicon — no PATH-persistence dance
  # needed. It needs sudo to write and may not exist yet on Apple Silicon
  # (Homebrew uses /opt/homebrew), so create it best-effort.
  if [ "${INSTALL_TIER:-}" = "0" ]; then
    TB_TOOLS_DIR="${HOME}/.local/bin"
    TB_TOOLS_SUDO=""
    mkdir -p "$TB_TOOLS_DIR"
    case ":$PATH:" in *":$TB_TOOLS_DIR:"*) ;; *) export PATH="$TB_TOOLS_DIR:$PATH" ;; esac
  else
    TB_TOOLS_DIR="/usr/local/bin"
    TB_TOOLS_SUDO="sudo"
    sudo mkdir -p "$TB_TOOLS_DIR" 2>/dev/null || true
  fi
  local _saved_umask
  _saved_umask=$(umask)
  umask 022                # binaries must be world-executable, not owner-only (umask 077)
  install_kubectl
  install_k3d
  install_helm             # ends with success "System tools"
  umask "$_saved_umask"
  # Self-gates on TB_TOOLS_DIR being ~/.local/bin, so this is a no-op on every
  # other tier. It is already macOS-aware (_tools_rc_for_shell → ~/.zshrc for
  # zsh, the default shell on modern macOS).
  _persist_tools_on_path
}

# Configure login autostart so a rebooted Mac brings the container runtime — and thus
# tracebloc (the k3d nodes carry --restart unless-stopped) — back with ZERO human
# action (#430). A per-user LaunchAgent (no admin needed) runs at each login:
# `open -a Docker` on a GUI Mac, `colima start` on a headless one. Best-effort — never
# fail the install over autostart. Sets TB_MACOS_AUTOSTART=1 so the summary can honestly
# promise auto-restart. Dir overridable (TB_LAUNCHAGENTS_DIR) + launchctl mockable for tests.
# Emit a launchd plist to stdout: Label, RunAtLoad, ProgramArguments=$@, a per-user
# LOGPATH for std{out,err}, plus any raw EXTRA XML (e.g. a boot daemon's UserName/
# EnvironmentVariables). Kept separate so the GUI LaunchAgent and the headless
# LaunchDaemon share one skeleton (bash-3.2-safe). LOGPATH must be per-user (not a fixed
# /tmp path): with the installer's umask 077 a shared /tmp log is created 0600 by the
# first account and a second account's job then can't open it (EX_CONFIG → runtime never
# starts), and /tmp is symlink-plantable on a shared Mac (#430 Bugbot).
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

# Configure autostart so a rebooted Mac brings the container runtime — and thus tracebloc
# (k3d nodes carry --restart unless-stopped) — back with ZERO human action (#430).
#   • GUI Mac      → per-user LaunchAgent (~/Library/LaunchAgents, no admin) that opens
#                    Docker Desktop at each GUI login.
#   • headless Mac → a LaunchAgent would NEVER run (it loads only in a GUI/Aqua login
#                    session, which a headless box has none of; #430 Bugbot). Reboot
#                    recovery needs a system LaunchDaemon (/Library/LaunchDaemons, root)
#                    that runs `colima start` at BOOT as the install user.
# Honors TRACEBLOC_SKIP_AUTOSTART (and TRACEBLOC_NO_AUTOSTART until remove_by
# 2026-12-31), the same opt-out that gates ensure_cluster_autostart and
# the Windows peer (#430 Bugbot). Best-effort; TB_MACOS_AUTOSTART is set ONLY on success,
# so the summary's reboot promise stays honest.
_install_macos_autostart() {
  # $1 (optional) "no-sudo": forbid any privileged (sudo) write. Tier 0 promised
  # "no administrator rights needed" and holds no sudo credential (client#704), so
  # it passes this. The GUI LaunchAgent path never needs sudo and is unchanged;
  # only the headless LaunchDaemon path — which does — is gated below.
  local _no_sudo=""
  if [[ "${1:-}" == "no-sudo" ]]; then _no_sudo=1; fi
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" || -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then
    log "Autostart skipped (TRACEBLOC_SKIP_AUTOSTART/TRACEBLOC_NO_AUTOSTART set)."
    return 0
  fi
  local label="io.tracebloc.runtime"
  if _has_gui_session; then
    local dir="${TB_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
    local plist="$dir/${label}.plist"
    mkdir -p "$dir" 2>/dev/null || {
      warn "Couldn't create ${dir}; skipping login autostart — open Docker Desktop manually after a reboot."
      return 1
    }
    mkdir -p "$HOME/Library/Logs" 2>/dev/null || true
    _emit_launch_plist "$label" "" "$HOME/Library/Logs/tracebloc-autostart.log" /usr/bin/open -a Docker > "$plist" 2>/dev/null || {
      warn "Couldn't write the login autostart agent at ${plist}; open Docker Desktop manually after a reboot."
      return 1
    }
    # RunAtLoad handles every future GUI login; bootstrap it into THIS session too.
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null \
      || launchctl load -w "$plist" 2>/dev/null || true
  else
    # Tier 0 (no-sudo): a headless Mac's only reboot-recovery mechanism is a system
    # LaunchDaemon (a user LaunchAgent never loads without a GUI/Aqua session; #430),
    # and writing it needs root. Tier 0 must NOT prompt for a password — that is the
    # exact step-b failure it exists to remove (client#704) — so skip the boot daemon
    # honestly and say how to enable it later. Best-effort: the caller's `|| true` and
    # TB_MACOS_AUTOSTART staying unset keep the summary's reboot line truthful.
    if [[ -n "$_no_sudo" ]]; then
      # ALREADY HANDLED? Tier 0 means someone else provisioned this box, so a
      # previous ADMIN install may have left the boot daemon in place. Skipping
      # the write is still correct (we hold no sudo), but reporting "start it
      # yourself" would be false — autostart is configured, just not by us.
      # Checked before the warn so a solved machine says nothing alarming.
      local _dir="${TB_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
      if [[ -f "$_dir/${label}.plist" ]]; then
        log "Headless Tier 0: boot LaunchDaemon ${label} is already installed; autostart needs nothing from us."
        TB_MACOS_AUTOSTART=1
        return 0
      fi
      warn "Headless reboot autostart needs a system LaunchDaemon (admin/root); this no-admin (Tier 0) install won't prompt for a password, so it's skipped."
      # NAME A COMMAND ONLY IF IT IS ACTUALLY HERE. The privileged path below
      # resolves colima the same way and softens to a generic message when it is
      # absent (#430 Bugbot); this path named `colima start` unconditionally,
      # which on a non-colima headless runtime is a command that does not exist.
      local _colima; _colima="$(command -v colima 2>/dev/null || true)"
      if [[ -n "$_colima" ]]; then
        hint "To get auto-restart after a reboot: run 'colima start' yourself after boot, or re-run this installer from an administrator account to install the boot LaunchDaemon."
        TB_MACOS_MANUAL_RUNTIME_CMD="colima start"
      else
        hint "To get auto-restart after a reboot: start your Docker runtime manually after boot, or re-run this installer from an administrator account to install the boot LaunchDaemon."
      fi
      # Tell the summary WHICH manual recovery applies (Bugbot, client#704).
      # Leaving only TB_MACOS_AUTOSTART unset is not enough: _reboot_note's
      # not-configured branch is the macOS/Windows GUI fallback and says "open
      # Docker Desktop", which on a headless Mac names a runtime that is not
      # here and an action there is no GUI to perform — and contradicts the hint
      # printed just above. That footer is the LAST line of a successful
      # install, so it is the advice the operator actually leaves with.
      TB_MACOS_HEADLESS_NO_AUTOSTART=1
      return 1
    fi
    # The headless daemon runs colima — but only if colima is ACTUALLY the runtime here.
    # install_docker_desktop installs colima ONLY when Docker was down; if Docker was
    # already up by other means colima may be absent, so a colima daemon would be bogus and
    # the auto-restart promise false (#430 Bugbot). Resolve colima's REAL path (Homebrew is
    # /opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel) instead of baking a fixed
    # one; if it isn't installed, skip autostart honestly (best-effort — caller's `|| true`)
    # rather than promise recovery via a runtime that isn't there.
    local _colima; _colima="$(command -v colima 2>/dev/null || true)"
    if [[ -z "$_colima" ]]; then
      warn "Headless autostart needs colima, but it isn't installed on this host; skipping boot autostart — start your Docker runtime manually after a reboot."
      return 1
    fi
    local dir="${TB_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
    local plist="$dir/${label}.plist"
    local _user; _user="$(id -un)"
    local _home="${HOME:-/Users/$_user}"
    # A boot daemon has no user env — colima/limactl need HOME + a PATH that finds colima
    # and its deps, and must run AS the install user (not root), or the VM/socket land in
    # the wrong place. RunAtLoad fires at boot with no login.
    local extra
    printf -v extra '%s\n%s\n%s\n%s\n%s\n%s' \
      "  <key>UserName</key><string>${_user}</string>" \
      '  <key>EnvironmentVariables</key>' \
      '  <dict>' \
      "    <key>HOME</key><string>${_home}</string>" \
      '    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>' \
      '  </dict>'
    sudo mkdir -p "$dir" 2>/dev/null || {
      warn "Couldn't create ${dir}; skipping boot autostart — run 'colima start' manually after a reboot."
      return 1
    }
    # The daemon logs as the install user; create the log dir first — a fresh headless
    # account may lack ~/Library/Logs, and launchd fails EX_CONFIG (colima never runs) when
    # the StandardOutPath directory is missing (#430 Bugbot). Same mkdir the GUI path does.
    mkdir -p "${_home}/Library/Logs" 2>/dev/null || true
    # Resilient boot start: a bare oneshot `colima start` at boot is fragile — the VZ+Rosetta
    # stack commonly leaves stale VM state across a reboot, so the first start fails. Retry a
    # few times, `colima stop --force`-ing between attempts to actually clear the orphaned VZ
    # driver state (a bare `stop` neither clears it nor is guaranteed to return; #430 Bugbot).
    # The loop body has no <, >, or & so it stays valid inside the plist <string>.
    local _boot
    _boot="tries=0; until ${_colima} start; do tries=\$((tries+1)); if [ \$tries -ge 3 ]; then exit 1; fi; ${_colima} stop --force; sleep 15; done"
    _emit_launch_plist "$label" "$extra" "${_home}/Library/Logs/tracebloc-autostart.log" /bin/bash -c "$_boot" | sudo tee "$plist" >/dev/null 2>&1 || {
      warn "Couldn't write the boot autostart daemon at ${plist}; run 'colima start' manually after a reboot."
      return 1
    }
    # System domain, at boot, no login required.
    sudo launchctl bootstrap system "$plist" 2>/dev/null \
      || sudo launchctl load -w "$plist" 2>/dev/null || true
  fi
  TB_MACOS_AUTOSTART=1
  success "Autostart configured — tracebloc returns automatically after a reboot."
  return 0
}

# Verify amd64 emulation ACTUALLY works before a cluster starts scheduling the
# amd64-only client images (#433). On Apple Silicon a green arch preflight only means
# Docker *should* emulate — but Docker Desktop's "Use Rosetta for x86_64/amd64
# emulation" can be off, or colima can lack it, and then the images crash-loop with an
# exec-format error minutes later with no earlier signal. Force-run a tiny amd64 binary
# NOW (Docker is up by this point) and fail here, naming the exact setting, instead of
# in a pod. Intel Macs run amd64 natively — nothing to check. TRACEBLOC_ALLOW_ARM64
# skips it (same escape hatch as the preflight arch gate). Image overridable for tests.
# The macOS amd64-emulation refusal — the Rosetta remedy. Shared by the early gate
# (assert_amd64_emulation) and the late _assert_engine_runs_on_this_arch backstop, so
# a refusal from either gives the same macOS-correct fix, never the Linux binfmt one.
_macos_amd64_refusal() {
  warn "amd64 emulation isn't working on this Apple Silicon Mac, and this install resolved to the amd64-only MySQL 5.7 engine — it would crash-loop, not fail here."
  hint "  Docker Desktop: Settings → General → enable \"Use Rosetta for x86_64/amd64 emulation\", then restart Docker and re-run."
  hint "  Colima: recreate the VM with VZ + Rosetta →  colima delete && colima start --vm-type vz --vz-rosetta"
  hint "  (or set TRACEBLOC_ALLOW_ARM64=1 to proceed anyway — the images may crash.)"
  error "amd64 emulation unavailable — fix the above and re-run (this install needs the amd64-only MySQL 5.7 engine; a fresh install would use the native 8.4 engine instead)."
}

# Boolean: does amd64 emulation actually run on this Mac? The Rosetta/Docker smoke,
# time-bounded (installer rule — every docker call is bounded; #433). spin_cmd_bounded
# returns 124 on the deadline -> false, same as a real emulation failure. Shared by
# the EARLY gate (assert_amd64_emulation) and the LATE _assert_engine_runs_on_this_arch
# backstop (client#756), so "can this arm64 Mac run amd64?" has one answer in one place.
_macos_amd64_emulation_ok() {
  local _img="${TB_AMD64_SMOKE_IMAGE:-busybox:1.36}"
  spin_cmd_bounded "${TB_AMD64_SMOKE_TIMEOUT:-120}" "Verifying amd64 emulation…" \
    docker run --rm --platform linux/amd64 "$_img" true
}

assert_amd64_emulation() {
  [[ "$ARCH" == "arm64" ]] || return 0
  if [[ -n "${TRACEBLOC_ALLOW_ARM64:-}" ]]; then
    warn "Skipping the amd64 emulation smoke test (TRACEBLOC_ALLOW_ARM64 set) — amd64 images may crash."
    return 0
  fi
  # Only the amd64-only MySQL 5.7 image needs emulation; the multi-arch 8.4 engine
  # runs natively on Apple Silicon. Ask through _pf_mysql_engine_decision, NOT the
  # raw _mysql_engine_decision: the wrapper sets values_file AND the SANITISED
  # TB_NAMESPACE (DNS-1123), so the per-release datadir HOST_DATA_DIR/<ns>/mysql is
  # probed, not just the legacy HOST_DATA_DIR/mysql. The wrapper also FAILS CLOSED to
  # 5.7 if the engine lib is unavailable. This is the EARLY gate (before helm), so
  # existing_id is invisible and the 8.4 answer is a GUESS; _assert_engine_runs_on_this_arch
  # re-asks on macOS once the engine is real and refuses there if the guess was wrong
  # (client#756). A FRESH Mac resolves to 8.4 and is not refused for emulation it does
  # not need (client#748). ${_decision%% *} keeps the reason attached, as _pf_arch does;
  # no 2>/dev/null — the wrapper always exits 0, so a real stderr diagnostic should show.
  local _decision _engine
  _decision="$(_pf_mysql_engine_decision)"
  _engine="${_decision%% *}"
  if [[ "$_engine" == "8.4" ]]; then
    success "MySQL engine resolves to 8.4 (multi-arch) — this Apple Silicon Mac runs the client images natively, no amd64 emulation needed."
    return 0
  fi
  if _macos_amd64_emulation_ok; then
    success "amd64 emulation verified (x86_64 client images will run)."
    return 0
  fi
  _macos_amd64_refusal
}

install_macos() {
  # Breadcrumbs (client#681). Step b was the one step that could fail before ANY
  # of its stages printed, leaving a log whose last line was the step header — so
  # even the ERR trap's location had nothing to corroborate it. These cost one
  # log line each and make the log say how far it got, trap or no trap.
  log "step b: install_macos starting (OS=$OS ARCH=$ARCH tier=${INSTALL_TIER:-?})"

  # ── Tier 0 — a container runtime is already usable as this user, so there is
  # nothing privileged left to do (RFC 0001 #1175). This is the macOS
  # counterpart of install_linux's Tier 0 branch, which macOS never got.
  #
  # It is the defect behind client#703: a Mac with Docker Desktop installed AND
  # running was still sent through _macos_require_admin + preflight_sudo and
  # died there — demanding an administrator password to install a runtime that
  # was already installed and answering. Docker Desktop, Homebrew and the admin
  # gate are all pointless here; only the pinned CLI tools are still missing,
  # and those install with no sudo at all.
  #
  # Skipping the admin gate is deliberate, not incidental: Tier 0 is exactly the
  # case RFC 0001 opened up — a user with no administrator rights on a machine
  # where someone else already provisioned the runtime.
  if [ "${INSTALL_TIER:-}" = "0" ]; then
    info "Using the container runtime already on this machine — no administrator rights needed."
    log "step b: tier 0 — skipping admin, sudo, Homebrew and Docker Desktop"
    assert_amd64_emulation    # Docker is up by definition here (#433)
    # THE TIER 0 CALL IS THE ONE THAT MATTERS (Cursor Bugbot High on #832). An
    # already-running Colima VM is exactly what Tier 0 classifies
    # (PROBE_RUNTIME_USABLE=1), and this branch RETURNS before
    # install_docker_desktop -- where the offer used to live exclusively. So the
    # feature never fired on the only machines it is for: an existing, under-sized
    # VM still got nothing but the preflight warning. The "already-running headless"
    # branch in install_docker_desktop was dead in practice, because Tier 0 catches
    # that machine first.
    #
    # Placed BEFORE the tool install so the consent prompt comes early, rather than
    # after a long download the user then has to sit through twice.
    _offer_colima_memory_raise
    _offer_desktop_memory_raise
    install_macos_cli_tools
    log "step b: cli tools ready (tier 0)"
    # Autostart stays best-effort here AND must make NO sudo call (client#704):
    # the GUI LaunchAgent needs no admin, while the headless LaunchDaemon (which
    # does) is skipped with instructions rather than prompting for the very
    # password Tier 0 exists to avoid. A failed login item never fails the install.
    _install_macos_autostart no-sudo || true
    return 0
  fi

  _macos_require_admin        # #430: no-admin Macs get a named IT remedy, not a generic sudo error
  log "step b: admin check passed"
  preflight_sudo
  log "step b: sudo ready"
  install_homebrew
  log "step b: homebrew ready"
  install_docker_desktop
  log "step b: docker ready"
  assert_amd64_emulation      # Docker is up now — prove amd64 runs before the cluster needs it (#433)
  install_macos_cli_tools
  log "step b: cli tools ready"
  # Best-effort: autostart returns 1 on a mkdir/write failure, and this runs under
  # `set -e` after Docker + tools are already installed — so `|| true` keeps a failed
  # login-item from aborting an otherwise-complete install (#430 Bugbot). The summary
  # stays honest either way: TB_MACOS_AUTOSTART is only set on success.
  _install_macos_autostart || true   # #430: login autostart so a rebooted Mac returns with zero action
}
