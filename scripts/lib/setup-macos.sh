#!/usr/bin/env bash
# =============================================================================
#  setup-macos.sh — macOS prerequisites: Homebrew, Docker Desktop, kubectl,
#                   k3d, helm
# =============================================================================

install_homebrew() {
  step "Step 1/3 — Homebrew"
  if ! has brew; then
    spin_cmd "Installing Homebrew…" env NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ "$ARCH" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      grep -q 'homebrew' "$HOME/.zprofile" 2>/dev/null || \
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    success "Homebrew installed."
  else
    success "Homebrew: $(brew --version | head -1)"
  fi
}

install_docker_desktop() {
  step "Step 2/3 — Docker Desktop"

  local fresh_install=false

  if ! has docker; then
    fresh_install=true

    # Detect real hardware — sysctl is immune to Rosetta translation
    local real_arch
    if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
      real_arch="arm64"
    else
      real_arch="amd64"
    fi

    info "Detected hardware architecture: $real_arch"

    local dmg_url="https://desktop.docker.com/mac/main/${real_arch}/Docker.dmg"
    local dmg_path="/tmp/Docker.dmg"

    retry 3 5 download_with_progress "$dmg_url" "$dmg_path" \
      "Downloading Docker Desktop ($real_arch)"

    spin_cmd "Installing Docker Desktop…" bash -c \
      "hdiutil attach '$dmg_path' -quiet && \
       cp -R '/Volumes/Docker/Docker.app' /Applications/ && \
       hdiutil detach '/Volumes/Docker' -quiet 2>/dev/null; \
       rm -f '$dmg_path'"

    success "Docker Desktop ($real_arch) installed to /Applications."
  fi

  # Verify the installed binary matches real hardware
  local docker_arch
  docker_arch="$(file /Applications/Docker.app/Contents/MacOS/Docker 2>/dev/null || true)"
  if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
    if echo "$docker_arch" | grep -q 'x86_64' && ! echo "$docker_arch" | grep -q 'arm64'; then
      warn "Docker binary appears to be Intel (x86_64) on Apple Silicon hardware."
      warn "Remove it and re-run: rm -rf /Applications/Docker.app"
    fi
  fi

  # ── First-time install: guided pause ──────────────────────────────────────
  if [[ "$fresh_install" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Docker Desktop needs a one-time setup.${RESET}"
    echo -e "  We'll open it for you now. Here's what to do:"
    echo ""
    echo -e "    1. ${CYAN}Accept the license agreement${RESET} in the Docker window"
    echo -e "    2. ${CYAN}Wait for the whale icon${RESET} 🐳 to appear in your menu bar"
    echo -e "    3. ${CYAN}Re-run this script${RESET} once Docker is ready"
    echo ""
    open -a Docker
    info "Opening Docker Desktop…"
    echo ""
    echo -e "  ${BOLD}This is completely normal — it only happens once.${RESET}"
    echo -e "  The script will now exit. Re-run it after Docker finishes its setup."
    echo ""
    exit 0
  fi

  # ── Docker already installed — just make sure it's running ────────────────
  if ! docker info &>/dev/null 2>&1; then
    open -a Docker

    local max_wait=40
    tput civis 2>/dev/null || true
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local f=0
    for i in $(seq 1 $max_wait); do
      if docker info &>/dev/null 2>&1; then break; fi
      printf "\r  ${CYAN}%s${RESET} Waiting for Docker Desktop to start…" "${frames[f]}"
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
    echo -e "    1. Look for the ${CYAN}whale icon${RESET} 🐳 in your menu bar"
    echo -e "    2. If Docker is open, wait until it says ${CYAN}\"Docker Desktop is running\"${RESET}"
    echo -e "    3. ${CYAN}Re-run this script${RESET} once it's ready"
    echo ""
    echo -e "  ${BOLD}Nothing is broken — Docker just needs a moment.${RESET}"
    echo ""
    exit 0
  fi

  success "Docker: $(docker --version)"
}

install_macos_cli_tools() {
  step "Step 3/3 — kubectl, k3d & helm"

  if ! has kubectl; then
    spin_cmd "Installing kubectl…" brew install kubectl
    success "kubectl: $(kubectl version --client --short 2>/dev/null || echo installed)"
  else
    success "kubectl: $(kubectl version --client --short 2>/dev/null || echo installed)"
  fi

  if ! has k3d; then
    spin_cmd "Installing k3d…" brew install k3d
    success "k3d: $(k3d version | head -1)"
  else
    success "k3d: $(k3d version | head -1)"
  fi

  if ! has helm; then
    spin_cmd "Installing helm…" brew install helm
    success "helm: $(helm version --short 2>/dev/null || echo installed)"
  else
    success "helm: $(helm version --short 2>/dev/null || echo installed)"
  fi
}

install_macos() {
  preflight_sudo
  install_homebrew
  install_docker_desktop
  install_macos_cli_tools
}
