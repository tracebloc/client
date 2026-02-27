#!/usr/bin/env bash
# =============================================================================
#  setup-linux.sh — Linux prerequisites: package manager, Docker Engine,
#                   system deps, kubectl, k3d, helm, GPU dispatch
# =============================================================================

# ── Package manager detection ────────────────────────────────────────────────
setup_pm() {
  if   has apt-get; then PM_UPDATE="sudo apt-get update -qq";           PM_INSTALL="sudo apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  elif has dnf;     then PM_UPDATE="sudo dnf makecache -q";             PM_INSTALL="sudo dnf install -y -q"
  elif has yum;     then PM_UPDATE="sudo yum makecache -q";             PM_INSTALL="sudo yum install -y -q"
  elif has zypper;  then PM_UPDATE="sudo zypper refresh -q";            PM_INSTALL="sudo zypper install -y"
  elif has pacman;  then PM_UPDATE="sudo pacman -Sy --noconfirm";       PM_INSTALL="sudo pacman -S --noconfirm"
  else error "No supported package manager (apt/dnf/yum/zypper/pacman) found."; fi
}

# ── Docker Engine ────────────────────────────────────────────────────────────
install_docker_engine() {
  step "Step 1/5 — Docker Engine"
  if ! has docker; then
    if [[ -f /etc/os-release ]] && grep -qi 'amzn\|amazon' /etc/os-release; then
      if has dnf; then spin_cmd "Installing Docker (Amazon Linux)…" sudo dnf install -y docker
      else              spin_cmd "Installing Docker (Amazon Linux)…" sudo yum install -y docker; fi
    elif has pacman; then
      spin_cmd "Installing Docker (Arch Linux)…" sudo pacman -S --noconfirm docker
    elif has zypper; then
      spin_cmd "Installing Docker (openSUSE/SLES)…" sudo zypper install -y docker
    else
      spin_cmd "Installing Docker…" retry 3 5 bash -c 'curl -fsSL https://get.docker.com | sudo bash'
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    success "Docker installed."
  else
    success "Docker: $(docker --version)"
  fi

  sudo systemctl start docker 2>/dev/null || true

  if ! docker info &>/dev/null 2>&1; then
    if [[ -z "${_K3S_INSTALL_REEXEC:-}" ]] && id -nG "$USER" 2>/dev/null | grep -qw docker; then
      SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
      warn "Docker group not yet active in this session — re-executing script..."
      exec sg docker -c "_K3S_INSTALL_REEXEC=1 bash '$SELF'"
    fi
    error "Could not connect to Docker daemon. Try logging out and back in, then re-run the script."
  fi
  success "Docker daemon running."
}

# ── System dependencies ─────────────────────────────────────────────────────
install_system_deps() {
  step "Step 2/5 — System dependencies"
  MISSING_PKGS=()
  has curl      || MISSING_PKGS+=(curl)
  has conntrack || MISSING_PKGS+=(conntrack-tools)
  if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    spin_cmd "Updating package index…" $PM_UPDATE
    for pkg in "${MISSING_PKGS[@]}"; do
      spin_cmd "Installing $pkg…" $PM_INSTALL "$pkg" || \
        warn "Could not install $pkg — may already be satisfied by an alternative package."
    done
    success "Dependencies installed: ${MISSING_PKGS[*]}"
  else
    success "System dependencies present."
  fi
}

# ── kubectl ──────────────────────────────────────────────────────────────────
_fetch_kubectl() {
  local ver="$1" arch="$2"
  retry 3 5 curl -fsSLO "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"
  retry 3 5 curl -fsSLO "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl.sha256"
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --quiet
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
  rm -f kubectl.sha256
}

install_kubectl() {
  step "Step 3/5 — kubectl"
  if ! has kubectl; then
    KUBE_VER=$(retry 3 5 curl -fsSL https://dl.k8s.io/release/stable.txt)
    spin_cmd "Installing kubectl $KUBE_VER…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
    success "kubectl $KUBE_VER installed."
  else
    success "kubectl: $(kubectl version --client --short 2>/dev/null || echo present)"
  fi
}

# ── k3d ──────────────────────────────────────────────────────────────────────
install_k3d() {
  step "Step 4/5 — k3d"
  if ! has k3d; then
    spin_cmd "Installing k3d…" \
      retry 3 5 bash -c 'curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash'
    success "k3d: $(k3d version | head -1)"
  else
    success "k3d: $(k3d version | head -1)"
  fi
}

# ── Helm ─────────────────────────────────────────────────────────────────────
install_helm() {
  step "Step 5/5 — Helm"
  if ! has helm; then
    spin_cmd "Installing Helm…" \
      retry 3 5 bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
    success "helm: $(helm version --short 2>/dev/null || echo installed)"
  else
    success "helm: $(helm version --short 2>/dev/null || echo present)"
  fi
}

# ── GPU setup dispatch ───────────────────────────────────────────────────────
dispatch_gpu_setup() {
  case "$GPU_VENDOR" in
    nvidia) install_nvidia_drivers; install_nvidia_container_toolkit ;;
    amd)    install_rocm ;;
    *)      info "No GPU setup required." ;;
  esac
}

# ── Main Linux installer ────────────────────────────────────────────────────
install_linux() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  preflight_sudo
  setup_pm
  install_docker_engine
  install_system_deps
  install_kubectl
  install_k3d
  install_helm
  dispatch_gpu_setup
}
