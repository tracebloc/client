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
    spin_cmd "Installing Homebrew…" env NONINTERACTIVE=1 /bin/bash "$brew_script"
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
  printf '%s\n' $groups | grep -qx admin
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
    spin_cmd "Installing Docker…" brew install docker
    success "Docker"
  else
    success "Docker"
  fi

  if ! has colima; then
    spin_cmd "Installing container runtime…" brew install colima
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
  spin_cmd "Starting Docker runtime…" colima "${_colima_args[@]}"

  if ! docker info &>/dev/null 2>&1; then
    error "Docker did not start. Try running 'colima status' to investigate."
  fi

  success "Docker running."
}

install_docker_desktop() {

  # On headless Macs (EC2, CI runners), Docker Desktop can't launch.
  # If Docker is already running (e.g. started via VNC earlier), skip detection.
  if ! _has_gui_session && ! docker info &>/dev/null 2>&1; then
    _install_docker_colima
    return
  fi

  # Detect real hardware — sysctl is immune to Rosetta translation
  local real_arch
  if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
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
    echo "$docker_bin_arch" | grep -q 'arm64' && docker_is_arm=true
    echo "$docker_bin_arch" | grep -q 'x86_64' && docker_is_intel=true

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

    local checksum_url="${dmg_url}.sha256sum"
    local expected_hash
    expected_hash=$(curl_secure -fsSL "$checksum_url" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$expected_hash" ]]; then
      local actual_hash
      actual_hash=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
      if [[ "$actual_hash" != "$expected_hash" ]]; then
        rm -f "$dmg_path"
        error "Docker Desktop DMG checksum mismatch — download may be corrupted or tampered with"
      fi
      log "Docker Desktop checksum verified."
    else
      log "Could not fetch Docker Desktop checksum — skipping verification."
    fi

    spin_cmd "Installing Docker Desktop…" bash -c \
      "hdiutil attach '$dmg_path' -nobrowse -quiet && \
       cp -R '/Volumes/Docker/Docker.app' /Applications/ && \
       xattr -cr /Applications/Docker.app && \
       hdiutil detach '/Volumes/Docker' -quiet 2>/dev/null; \
       rm -f '$dmg_path'"

    log "Docker Desktop ($real_arch) installed to /Applications."
  fi

  _kill_lingering_docker

  # ── Make sure Docker Desktop is running ──────────────────────────────────
  if ! docker info &>/dev/null 2>&1; then
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
    tput civis 2>/dev/null || true
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local f=0
    for i in $(seq 1 $max_wait); do
      if docker info &>/dev/null 2>&1; then break; fi
      local elapsed=$(( i * 3 ))
      printf "\r  ${CYAN}%s${RESET} Waiting for Docker Desktop… (%ds)" "${frames[f]}" "$elapsed"
      f=$(( (f + 1) % ${#frames[@]} ))
      sleep 3
    done
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true
  fi

  if ! docker info &>/dev/null 2>&1; then
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
  # macOS has no Tier/rootless model, so it does NOT use _set_tools_target (the Linux
  # selector): land the pinned binaries in /usr/local/bin, which is on the default
  # login PATH (/etc/paths) on BOTH Intel and Apple Silicon — no PATH-persistence
  # dance needed. It needs sudo to write and may not exist yet on Apple Silicon
  # (Homebrew uses /opt/homebrew), so create it best-effort.
  TB_TOOLS_DIR="/usr/local/bin"
  TB_TOOLS_SUDO="sudo"
  sudo mkdir -p "$TB_TOOLS_DIR" 2>/dev/null || true
  local _saved_umask
  _saved_umask=$(umask)
  umask 022                # binaries must be world-executable, not owner-only (umask 077)
  install_kubectl
  install_k3d
  install_helm             # ends with success "System tools"
  umask "$_saved_umask"
}

# Configure login autostart so a rebooted Mac brings the container runtime — and thus
# tracebloc (the k3d nodes carry --restart unless-stopped) — back with ZERO human
# action (#430). A per-user LaunchAgent (no admin needed) runs at each login:
# `open -a Docker` on a GUI Mac, `colima start` on a headless one. Best-effort — never
# fail the install over autostart. Sets TB_MACOS_AUTOSTART=1 so the summary can honestly
# promise auto-restart. Dir overridable (TB_LAUNCHAGENTS_DIR) + launchctl mockable for tests.
_install_macos_autostart() {
  local dir="${TB_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
  local label="io.tracebloc.runtime"
  local plist="$dir/${label}.plist"
  local -a prog
  if _has_gui_session; then
    prog=( /usr/bin/open -a Docker )
  else
    local _colima; _colima="$(command -v colima 2>/dev/null || echo /usr/local/bin/colima)"
    prog=( "$_colima" start )
  fi
  mkdir -p "$dir" 2>/dev/null || {
    warn "Couldn't create ${dir}; skipping login autostart — start the runtime manually after a reboot."
    return 1
  }
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '  <key>Label</key><string>%s</string>\n' "$label"
    printf '%s\n' '  <key>ProgramArguments</key>'
    printf '%s\n' '  <array>'
    local _a
    for _a in "${prog[@]}"; do printf '    <string>%s</string>\n' "$_a"; done
    printf '%s\n' '  </array>'
    printf '%s\n' '  <key>RunAtLoad</key><true/>'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' '/tmp/tracebloc-autostart.log'
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' '/tmp/tracebloc-autostart.log'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$plist" 2>/dev/null || {
    warn "Couldn't write the login autostart agent at ${plist}; start the runtime manually after a reboot."
    return 1
  }
  # Register for this session (best-effort; RunAtLoad handles every future login).
  # bootstrap is the modern form; fall back to load -w on older macOS.
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null \
    || launchctl load -w "$plist" 2>/dev/null || true
  TB_MACOS_AUTOSTART=1
  success "Login autostart configured — tracebloc returns automatically after a reboot."
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
assert_amd64_emulation() {
  [[ "$ARCH" == "arm64" ]] || return 0
  if [[ -n "${TRACEBLOC_ALLOW_ARM64:-}" ]]; then
    warn "Skipping the amd64 emulation smoke test (TRACEBLOC_ALLOW_ARM64 set) — amd64 images may crash."
    return 0
  fi
  local _img="${TB_AMD64_SMOKE_IMAGE:-busybox:1.36}"
  # Time-bounded: a wedged daemon or stuck pull must not hang a headless install
  # forever behind a spinner (installer rule — every docker call is bounded; #433
  # Bugbot). spin_cmd_bounded returns 124 on the deadline, which falls through to the
  # same remediation as a real emulation failure.
  if spin_cmd_bounded "${TB_AMD64_SMOKE_TIMEOUT:-120}" "Verifying amd64 emulation…" \
       docker run --rm --platform linux/amd64 "$_img" true; then
    success "amd64 emulation verified (x86_64 client images will run)."
    return 0
  fi
  warn "amd64 emulation isn't working on this Apple Silicon Mac — the amd64-only tracebloc images would crash-loop, not fail here."
  hint "  Docker Desktop: Settings → General → enable \"Use Rosetta for x86_64/amd64 emulation\", then restart Docker and re-run."
  hint "  Colima: recreate the VM with VZ + Rosetta →  colima delete && colima start --vm-type vz --vz-rosetta"
  hint "  (or set TRACEBLOC_ALLOW_ARM64=1 to proceed anyway — the images may crash.)"
  error "amd64 emulation unavailable — fix the above and re-run (the client images are amd64-only)."
}

install_macos() {
  _macos_require_admin        # #430: no-admin Macs get a named IT remedy, not a generic sudo error
  preflight_sudo
  install_homebrew
  install_docker_desktop
  assert_amd64_emulation      # Docker is up now — prove amd64 runs before the cluster needs it (#433)
  install_macos_cli_tools
  # Best-effort: autostart returns 1 on a mkdir/write failure, and this runs under
  # `set -e` after Docker + tools are already installed — so `|| true` keeps a failed
  # login-item from aborting an otherwise-complete install (#430 Bugbot). The summary
  # stays honest either way: TB_MACOS_AUTOSTART is only set on success.
  _install_macos_autostart || true   # #430: login autostart so a rebooted Mac returns with zero action
}
