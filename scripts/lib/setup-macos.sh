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

  if ! has docker; then
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

    spin_cmd "Downloading Docker Desktop ($real_arch)…" \
      retry 3 5 curl -fSL -o "$dmg_path" "$dmg_url"

    spin_cmd "Installing Docker Desktop…" bash -c \
      "hdiutil attach '$dmg_path' -quiet && \
       cp -R '/Volumes/Docker/Docker.app' /Applications/ && \
       hdiutil detach '/Volumes/Docker' -quiet 2>/dev/null; \
       rm -f '$dmg_path'"

    success "Docker Desktop ($real_arch) installed to /Applications."
  fi

  if ! docker info &>/dev/null 2>&1; then
    info "Starting Docker Desktop..."
    open -a Docker
    info "First launch? Accept the Docker license agreement in the UI."
    sleep 5
  fi

  local max_wait=60
  echo -n "  Waiting for Docker engine"
  for i in $(seq 1 $max_wait); do
    docker info &>/dev/null 2>&1 && break
    echo -n "."; sleep 3
  done; echo ""

  if ! docker info &>/dev/null 2>&1; then
    warn "Docker did not start within $((max_wait * 3))s."
    warn "On first install, open Docker Desktop and accept the license agreement."
    error "Re-run this script once Docker Desktop is running."
  fi

  # Verify the installed Docker matches real hardware
  local docker_arch
  docker_arch="$(file /Applications/Docker.app/Contents/MacOS/Docker 2>/dev/null || true)"
  if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
    if echo "$docker_arch" | grep -q 'x86_64' && ! echo "$docker_arch" | grep -q 'arm64'; then
      warn "Docker binary appears to be Intel (x86_64) on Apple Silicon hardware."
      warn "Remove it and re-run: rm -rf /Applications/Docker.app"
    fi
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
  install_homebrew
  install_docker_desktop
  install_macos_cli_tools
}
