#!/usr/bin/env bash
# =============================================================================
#  setup-macos.sh — macOS prerequisites: Homebrew, Docker Desktop, kubectl,
#                   k3d, helm
# =============================================================================

install_homebrew() {
  if ! has brew; then
    local brew_script
    brew_script="$(mktemp)"
    curl -fsSL $CURL_SECURE https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
      -o "$brew_script"
    spin_cmd "Installing Homebrew…" env NONINTERACTIVE=1 /bin/bash "$brew_script"
    rm -f "$brew_script"
    if [[ "$ARCH" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      grep -q 'homebrew' "$HOME/.zprofile" 2>/dev/null || \
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    success "Homebrew installed."
  else
    success "Homebrew"
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

  spin_cmd "Starting Docker runtime…" colima start --cpu 2 --memory 4 --disk 60

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
        local reply
        read -r -p "  Replace wrong-architecture Docker with native version? [Y/n] " reply || true
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

    retry 3 5 download_with_progress "$dmg_url" "$dmg_path" \
      "Downloading Docker Desktop ($real_arch)"

    local checksum_url="${dmg_url}.sha256sum"
    local expected_hash
    expected_hash=$(curl -fsSL $CURL_SECURE "$checksum_url" 2>/dev/null | awk '{print $1}' || true)
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

  success "Docker"
}

install_macos_cli_tools() {
  if ! has kubectl; then
    spin_cmd "Installing system tools…" brew install kubectl
  fi
  log "kubectl: $(kubectl version --client --short 2>/dev/null || echo installed)"

  if ! has k3d; then
    spin_cmd "Installing system tools…" brew install k3d
  fi
  log "k3d: $(k3d version | head -1 2>/dev/null || echo installed)"

  if ! has helm; then
    spin_cmd "Installing system tools…" brew install helm
  fi
  log "helm: $(helm version --short 2>/dev/null || echo installed)"

  success "System tools"
}

install_macos() {
  preflight_sudo
  install_homebrew
  install_docker_desktop
  install_macos_cli_tools
}
