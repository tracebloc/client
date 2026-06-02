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
  else error "No supported package manager found."; fi
}

# ── Docker Engine ────────────────────────────────────────────────────────────
install_docker_engine() {
  if ! has docker; then
    if [[ -f /etc/os-release ]] && grep -qi 'amzn\|amazon' /etc/os-release; then
      if has dnf; then spin_cmd "Installing Docker…" sudo dnf install -y docker
      else              spin_cmd "Installing Docker…" sudo yum install -y docker; fi
    elif has pacman; then
      spin_cmd "Installing Docker…" sudo pacman -S --noconfirm docker
    elif has zypper; then
      spin_cmd "Installing Docker…" sudo zypper install -y docker
    elif [[ -f /etc/os-release ]] && grep -qiE '^ID="?(almalinux|rocky|ol|oracle)"?' /etc/os-release; then
      # get.docker.com rejects RHEL rebuilds (almalinux/rocky/ol) with
      # "Unsupported distribution". Install docker-ce from Docker's official
      # CentOS repo instead — it is RHEL-compatible and works on these distros.
      spin_cmd "Installing Docker…" bash -c '
        set -e
        sudo dnf -y -q install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo dnf -y -q install docker-ce docker-ce-cli containerd.io'
    else
      local docker_script
      docker_script="$(mktemp)"
      retry 3 5 curl -fsSL $CURL_SECURE https://get.docker.com -o "$docker_script"
      chmod +x "$docker_script"
      spin_cmd "Installing Docker…" sudo bash "$docker_script"
      rm -f "$docker_script"
    fi
    # Enable for boot only (no --now): starting is handled below, where a start
    # failure is diagnosed instead of aborting the whole script under `set -e`.
    sudo systemctl enable docker >/dev/null 2>&1 || true
    sudo usermod -aG docker "$USER"
    success "Docker"
  else
    success "Docker"
  fi

  # Clear any failed/throttled state from a previous attempt first — a crashed
  # daemon leaves the unit in "Start request repeated too quickly", which makes
  # systemctl refuse a plain start (so a bare re-run can never recover). Both
  # commands are best-effort; the `docker info` check below is the real gate.
  sudo systemctl reset-failed docker 2>/dev/null || true
  sudo systemctl start docker 2>/dev/null || true

  if ! docker info &>/dev/null 2>&1; then
    # (a) Group not active in THIS shell yet → re-exec under the docker group.
    if [[ -z "${_K3S_INSTALL_REEXEC:-}" ]] && id -nG "$USER" 2>/dev/null | grep -qw docker; then
      SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
      log "Docker group not yet active in this session — re-executing script..."
      exec sg docker -c "_K3S_INSTALL_REEXEC=1 bash '$SELF'"
    fi
    # (b) The daemon itself isn't running → a Docker/host problem, not a group
    # one. Surface Docker's OWN error (a 'log out and back in' hint would just
    # send the user in circles, as it can't fix a crashing daemon).
    if ! sudo systemctl is-active --quiet docker 2>/dev/null; then
      echo ""
      warn "Docker is installed, but its daemon won't start — this is a Docker/host issue, not tracebloc."
      hint "Common causes on RHEL/AlmaLinux: SELinux or iptables/nftables init, an overlay"
      hint "storage-driver problem, or too little space on /var/lib/docker. Docker's own error:"
      { sudo systemctl status docker.service --no-pager -l 2>&1 | tail -6
        sudo journalctl -u docker.service --no-pager 2>/dev/null \
          | grep -iE 'level=(error|fatal)|failed to|cannot |unable |no such' | tail -12; } | sed 's/^/    /'
      echo ""
      error "Start Docker manually (fix the error above), then re-run this installer."
    fi
    error "Could not connect to Docker. Try logging out and back in, then re-run the script."
  fi
  log "Docker daemon running."
}

# ── System dependencies ─────────────────────────────────────────────────────
install_system_deps() {
  # conntrack binary ships under different package names per distro:
  #   Debian/Ubuntu (apt) → "conntrack";  RHEL/SUSE/Arch (dnf/yum/zypper/pacman) → "conntrack-tools"
  local conntrack_pkg="conntrack-tools"
  has apt-get && conntrack_pkg="conntrack"
  MISSING_PKGS=()
  has curl      || MISSING_PKGS+=(curl)
  has conntrack || MISSING_PKGS+=("$conntrack_pkg")
  if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    spin_cmd "Updating package index…" $PM_UPDATE
    for pkg in "${MISSING_PKGS[@]}"; do
      spin_cmd "Installing $pkg…" $PM_INSTALL "$pkg" || \
        log "Could not install $pkg — may already be satisfied by an alternative package."
    done
    log "Dependencies installed: ${MISSING_PKGS[*]}"
  fi
  success "System dependencies"
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
    || { rm -rf "$tmpdir"; error "System tool checksum verification failed"; }
  chmod +x "${tmpdir}/kubectl"
  sudo mv "${tmpdir}/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmpdir"
}

install_kubectl() {
  if ! has kubectl; then
    KUBE_VER=$(retry 3 5 curl -fsSL $CURL_SECURE https://dl.k8s.io/release/stable.txt)
    spin_cmd "Installing system tools…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
    log "kubectl $KUBE_VER installed."
  else
    log "kubectl: $(kubectl version --client --short 2>/dev/null || echo present)"
  fi
}

# ── k3d ──────────────────────────────────────────────────────────────────────
install_k3d() {
  if has k3d; then
    log "k3d: $(k3d version | head -1)"
    return 0
  fi

  local k3d_script
  k3d_script="$(mktemp)"
  retry 3 5 curl -fsSL $CURL_SECURE \
    https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh -o "$k3d_script"
  chmod +x "$k3d_script"

  # Preserve PATH through sudo: the k3d install script verifies itself with
  # `command -v k3d` after copying the binary into /usr/local/bin. On RHEL-family
  # distros sudo's secure_path excludes /usr/local/bin, so that check fails and
  # the script aborts with "k3d not found". `sudo env PATH=$PATH` keeps it visible.
  if ! spin_cmd "Installing system tools…" sudo env "PATH=$PATH" bash "$k3d_script"; then
    rm -f "$k3d_script"
    error "System tool installation failed. See the install log for details."
  fi
  rm -f "$k3d_script"

  if ! has k3d; then
    error "System tool installation completed but not found on PATH."
  fi

  log "k3d: $(k3d version | head -1)"
}

# ── Helm ─────────────────────────────────────────────────────────────────────
_ensure_helm_executable() {
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -n "$helm_bin" && -f "$helm_bin" && ! -x "$helm_bin" ]]; then
    log "Making Helm executable (fixing permissions)..."
    sudo chmod 755 "$helm_bin" 2>/dev/null || true
  fi
}

install_helm() {
  if ! has helm; then
    local helm_script
    helm_script="$(mktemp)"
    retry 3 5 curl -fsSL $CURL_SECURE \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$helm_script"
    chmod +x "$helm_script"
    spin_cmd "Installing system tools…" bash "$helm_script"
    rm -f "$helm_script"
    _ensure_helm_executable
  else
    _ensure_helm_executable
  fi
  log "helm: $(helm version --short 2>/dev/null || echo installed)"
  success "System tools"
}

# ── GPU setup dispatch ───────────────────────────────────────────────────────
dispatch_gpu_setup() {
  case "$GPU_VENDOR" in
    nvidia) install_nvidia_drivers; install_nvidia_container_toolkit ;;
    amd)    install_rocm ;;
    *)      log "No GPU setup required." ;;
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

  # umask 077 (set in common.sh) would make binaries in /usr/local/bin/
  # executable only by root — relax to 022 for system tool installs
  local _saved_umask
  _saved_umask=$(umask)
  umask 022
  install_kubectl
  install_k3d
  install_helm
  umask "$_saved_umask"

  dispatch_gpu_setup
}
