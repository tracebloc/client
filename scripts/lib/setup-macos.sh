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
  if ! docker info &>/dev/null 2>&1 && pgrep -xq "Docker Desktop"; then
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

  if docker info &>/dev/null 2>&1; then
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

  if ! docker info &>/dev/null 2>&1; then
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
# Desktop's VM size lives in a settings file whose schema is version-dependent
# and, on a default install, does not contain a memory key at all -- Docker only
# persists what the user has changed (verified on macOS 15 / Docker Desktop:
# settings-store.json held ten keys and none of them was memory). Writing a
# guessed key name there would produce an installer that SAYS it raised the VM
# and did nothing, which is worse than the instruction it replaced. So Docker
# Desktop keeps the instruction that preflight already prints, and this path is
# deliberately Colima-only.
#
# CONSENT IS REQUIRED, because this stops the user's container runtime -- every
# running container goes down. The ticket asks for it explicitly and it is the
# right bar for a destructive-adjacent action:
#   * no usable TTY (CI, `curl | bash`) -> print the manual command and return.
#     A non-interactive run must never restart a runtime nobody asked it to.
#   * default is NO. A bare Enter declines.
#   * TRACEBLOC_ASSUME_YES=1 opts in for an unattended install that WANTS this.
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

  # Only when it is actually short. The same comparison preflight.sh:291 makes,
  # for the same reason.
  (( current_mib < PF_MIN_MEM_GB * 1024 - PF_VM_MEM_GRACE_MIB )) || return 0

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
  if (( target_gb < PF_MIN_MEM_GB )); then
    if [[ -n "${COLIMA_MEMORY:-}" ]]; then
      hint "COLIMA_MEMORY is set to ${COLIMA_MEMORY} GB, below the ${PF_MIN_MEM_GB} GB tracebloc needs to train. Raise or unset it."
    else
      hint "This Mac cannot spare ${PF_MIN_MEM_GB} GB for Docker (the most it can give is ${target_gb} GB), so raising the VM would not fix it. Training needs a larger machine."
    fi
    return 0
  fi

  # NO "is the raise worth a restart" GUARD HERE, and its absence is deliberate.
  # `(( target_gb > current_gb ))` used to sit on this line and is now UNREACHABLE:
  # reaching it requires the VM to be raw-short (`current_mib < floor*1024 - grace`)
  # AND the target to clear the floor, and those two cannot both hold. With
  # grace=512 and floor=5, short means `current_mib < 4608`, so
  # `current_gb = (current_mib + 512)/1024` is at most 4 while the target is at
  # least 5 -- the comparison is always true. Bugbot asked for a fixture that
  # exercises the line; no such fixture exists, so the line goes instead. The
  # sub-floor branch above is what actually rejects an unhelpful target.

  local cmd="colima stop && colima start --memory ${target_gb}"
  warn "Docker's Colima VM has ${current_gb} GB — below the ${PF_MIN_MEM_GB} GB tracebloc needs to train."

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
  local new_kb new_gb
  new_kb="$(_pf_runtime_mem_kb)"
  # Same grace-aware arithmetic as the grading above: truncating here would let a
  # raise that landed exactly ON the floor report that nothing grew.
  if [[ "$new_kb" =~ ^[0-9]+$ ]] &&
     (( $(_pf_display_gb_from_mib "$(( new_kb / 1024 ))") > current_gb )); then
    new_gb="$(_pf_display_gb_from_mib "$(( new_kb / 1024 ))")"
    success "Colima VM raised to ${new_gb} GB."
  else
    warn "Colima restarted but still reports ${current_gb} GB. Check 'colima status' and raise it manually: ${cmd}"
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
  if ! _has_gui_session && ! docker info &>/dev/null 2>&1; then
    _install_docker_colima
    # AFTER the runtime is up, so `docker info` can be read (backend#2221). A
    # fresh VM is already sized from physical RAM (#428) and this is a no-op on
    # it; an EXISTING under-sized VM is the case that had nothing but a warning.
    _offer_colima_memory_raise
    return
  fi
  # The already-running case: on a headless Mac whose Colima VM was started
  # earlier (VNC, a previous install) the branch above is skipped entirely, so
  # the offer has to be made here too or the exact machine that needs it -- one
  # with an old, small VM -- never sees it.
  if ! _has_gui_session; then
    _offer_colima_memory_raise
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
# Honors TRACEBLOC_NO_AUTOSTART, the same opt-out that gates ensure_cluster_autostart and
# the Windows peer (#430 Bugbot). Best-effort; TB_MACOS_AUTOSTART is set ONLY on success,
# so the summary's reboot promise stays honest.
_install_macos_autostart() {
  # $1 (optional) "no-sudo": forbid any privileged (sudo) write. Tier 0 promised
  # "no administrator rights needed" and holds no sudo credential (client#704), so
  # it passes this. The GUI LaunchAgent path never needs sudo and is unchanged;
  # only the headless LaunchDaemon path — which does — is gated below.
  local _no_sudo=""
  if [[ "${1:-}" == "no-sudo" ]]; then _no_sudo=1; fi
  if [[ -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then
    log "Autostart skipped (TRACEBLOC_NO_AUTOSTART set)."
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
