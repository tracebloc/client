#!/usr/bin/env bash
# =============================================================================
#  setup-macos.sh — macOS prerequisites: Homebrew, Docker Desktop, kubectl,
#                   k3d, helm
# =============================================================================

install_homebrew() {
  step "Step 1/3 — Homebrew"
  if ! has brew; then
    info "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
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
    info "Installing Docker Desktop..."
    brew install --cask docker
    open -a Docker
  elif ! docker info &>/dev/null 2>&1; then
    info "Starting Docker Desktop..."
    open -a Docker
  fi

  echo -n "  Waiting for Docker"
  for i in {1..40}; do
    docker info &>/dev/null 2>&1 && break
    echo -n "."; sleep 3
  done; echo ""
  docker info &>/dev/null 2>&1 || error "Docker didn't start. Open Docker Desktop manually and re-run."
  success "Docker: $(docker --version)"
}

install_macos_cli_tools() {
  step "Step 3/3 — kubectl, k3d & helm"
  has kubectl || brew install kubectl && success "kubectl: $(kubectl version --client --short 2>/dev/null || echo installed)"
  has k3d     || brew install k3d    && success "k3d: $(k3d version | head -1)"
  has helm    || brew install helm   && success "helm: $(helm version --short 2>/dev/null || echo installed)"
}

install_macos() {
  install_homebrew
  install_docker_desktop
  install_macos_cli_tools
}
