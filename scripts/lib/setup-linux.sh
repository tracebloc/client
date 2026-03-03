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
  elif has zypper;  then PM_UPDATE="sudo zypper refresh";               PM_INSTALL="sudo zypper install -y"
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
      local docker_script
      docker_script="$(mktemp)"
      retry 3 5 curl -fsSL $CURL_SECURE https://get.docker.com -o "$docker_script"
      chmod +x "$docker_script"
      spin_cmd "Installing Docker…" sudo bash "$docker_script"
      rm -f "$docker_script"
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
  local tmpdir
  tmpdir="$(mktemp -d)"
  retry 3 5 curl -fsSL $CURL_SECURE \
    "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl" -o "${tmpdir}/kubectl"
  retry 3 5 curl -fsSL $CURL_SECURE \
    "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl.sha256" -o "${tmpdir}/kubectl.sha256"
  echo "$(cat "${tmpdir}/kubectl.sha256")  ${tmpdir}/kubectl" | sha256sum --check --quiet \
    || { rm -rf "$tmpdir"; error "kubectl checksum verification failed — possible tampering"; }
  chmod +x "${tmpdir}/kubectl"
  sudo mv "${tmpdir}/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmpdir"
}

install_kubectl() {
  step "Step 3/5 — kubectl"
  if ! has kubectl; then
    KUBE_VER=$(retry 3 5 curl -fsSL $CURL_SECURE https://dl.k8s.io/release/stable.txt)
    spin_cmd "Installing kubectl $KUBE_VER…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
    success "kubectl $KUBE_VER installed."
  else
    success "kubectl: $(kubectl version --client --short 2>/dev/null || echo present)"
  fi
}

# ── k3d ──────────────────────────────────────────────────────────────────────
install_k3d() {
  step "Step 4/5 — k3d"
  # Fast-path: if k3d is already installed, just report and return.
  if has k3d; then
    success "k3d: $(k3d version | head -1)"
    return 0
  fi

  # Prefer distro package on openSUSE/SLES when available.
  if has zypper; then
    if spin_cmd "Installing k3d (openSUSE/SLES…)" sudo zypper install -y k3d; then
      success "k3d: $(k3d version | head -1)"
      return 0
    else
      warn "zypper k3d install failed — falling back to upstream GitHub installer."
    fi
  fi

  # Fallback: download latest k3d release directly from GitHub.
  local k3d_ver
  k3d_ver=$(retry 3 5 curl -fsSL $CURL_SECURE \
    "https://api.github.com/repos/k3d-io/k3d/releases/latest" \
    | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
  [[ -n "$k3d_ver" ]] || error "Could not determine latest k3d version"

  local k3d_url="https://github.com/k3d-io/k3d/releases/download/${k3d_ver}/k3d-linux-${ARCH_DL}"
  local k3d_tmp
  k3d_tmp="$(mktemp)"
  spin_cmd "Downloading k3d ${k3d_ver}…" \
    retry 3 5 curl -fsSL $CURL_SECURE "$k3d_url" -o "$k3d_tmp"

  local checksums
  checksums=$(retry 3 5 curl -fsSL $CURL_SECURE \
    "https://github.com/k3d-io/k3d/releases/download/${k3d_ver}/sha256sum.txt" 2>/dev/null || true)
  if [[ -n "$checksums" ]]; then
    local expected actual
    expected=$(echo "$checksums" | grep "k3d-linux-${ARCH_DL}$" | awk '{print $1}')
    actual=$(sha256sum "$k3d_tmp" | awk '{print $1}')
    if [[ -n "$expected" && "$actual" != "$expected" ]]; then
      rm -f "$k3d_tmp"
      error "k3d checksum verification failed — possible tampering"
    fi
    info "k3d checksum verified."
  else
    warn "Could not fetch k3d checksums — skipping verification."
  fi

  chmod +x "$k3d_tmp"
  sudo mv "$k3d_tmp" /usr/local/bin/k3d
  success "k3d ${k3d_ver} installed."
}

# ── Helm ─────────────────────────────────────────────────────────────────────
install_helm() {
  step "Step 5/5 — Helm"
  if ! has helm; then
    local helm_script
    helm_script="$(mktemp)"
    retry 3 5 curl -fsSL $CURL_SECURE \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$helm_script"
    chmod +x "$helm_script"
    spin_cmd "Installing Helm…" bash "$helm_script"
    rm -f "$helm_script"
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
