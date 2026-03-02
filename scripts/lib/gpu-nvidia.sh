#!/usr/bin/env bash
# =============================================================================
#  gpu-nvidia.sh — NVIDIA driver installation + Container Toolkit (Linux)
# =============================================================================

# ── Drivers ──────────────────────────────────────────────────────────────────
install_nvidia_drivers() {
  if $NVIDIA_DRIVER_OK; then
    success "NVIDIA drivers already loaded."
    return
  fi

  step "Installing NVIDIA Drivers"
  warn "NVIDIA GPU present but drivers are missing — attempting auto-install..."

  $PM_UPDATE
  if has apt-get; then
    $PM_INSTALL ubuntu-drivers-common 2>/dev/null || true
    if has ubuntu-drivers; then
      sudo ubuntu-drivers install --gpgpu 2>/dev/null || sudo ubuntu-drivers autoinstall
    else
      LATEST_PKG=$(apt-cache search "^nvidia-driver-[0-9]" 2>/dev/null \
        | awk '{print $1}' | sort -t- -k3 -n | tail -1)
      [[ -n "$LATEST_PKG" ]] && $PM_INSTALL "$LATEST_PKG" || $PM_INSTALL nvidia-driver-535
    fi
  elif has dnf; then
    sudo dnf install -y epel-release 2>/dev/null || true
    # Detect RHEL/CentOS major and arch for correct NVIDIA repo (rhel8/rhel9, x86_64/aarch64)
    local rhel_major rhel_arch
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      rhel_major="${VERSION_ID%%.*}"
      rhel_major="${rhel_major:-9}"
    else
      rhel_major="9"
    fi
    case "$(uname -m)" in
      x86_64)  rhel_arch="x86_64" ;;
      aarch64|arm64) rhel_arch="sbsa" ;;
      *)       rhel_arch="x86_64" ;;
    esac
    sudo dnf config-manager --add-repo \
      "https://developer.download.nvidia.com/compute/cuda/repos/rhel${rhel_major}/${rhel_arch}/cuda-rhel${rhel_major}.repo" 2>/dev/null || true
    sudo dnf module install -y nvidia-driver:latest-dkms 2>/dev/null || \
      sudo dnf install -y akmod-nvidia || true
  elif has pacman; then
    $PM_INSTALL nvidia nvidia-utils
  fi

  warn "Drivers installed — a REBOOT is likely required before they activate."
  warn "After rebooting, re-run this script; driver steps will be skipped automatically."
  if [[ -n "${TRACEBLOC_SKIP_REBOOT_PROMPT:-}" ]]; then
    warn "TRACEBLOC_SKIP_REBOOT_PROMPT set — skipping reboot prompt. Reboot manually and re-run (exit 2)."
    exit 2
  fi
  read -r -p "  Reboot now? [y/N]: " _choice
  [[ "$_choice" =~ ^[Yy]$ ]] && sudo reboot
  warn "Skipping reboot. GPU steps may fail if the kernel module isn't loaded yet."
}

# ── Container Toolkit ────────────────────────────────────────────────────────
install_nvidia_container_toolkit() {
  step "NVIDIA Container Toolkit"

  if has nvidia-ctk && nvidia-ctk --version &>/dev/null 2>&1; then
    success "NVIDIA Container Toolkit already installed."
  else
    info "Installing nvidia-container-toolkit..."

    if has apt-get; then
      local nvidia_gpg_tmp
      nvidia_gpg_tmp="$(mktemp)"
      curl -fsSL $CURL_SECURE https://nvidia.github.io/libnvidia-container/gpgkey \
        -o "$nvidia_gpg_tmp"
      local nvidia_fp
      nvidia_fp=$(gpg --with-colons --import-options show-only --import "$nvidia_gpg_tmp" 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')
      if [[ -n "$nvidia_fp" ]]; then
        info "NVIDIA GPG key fingerprint: $nvidia_fp"
      else
        warn "Could not extract GPG key fingerprint — verify manually after install."
      fi
      sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$nvidia_gpg_tmp"
      rm -f "$nvidia_gpg_tmp"
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      sudo apt-get update -qq
      $PM_INSTALL nvidia-container-toolkit

    elif has dnf || has yum; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
      has dnf && sudo dnf install -y nvidia-container-toolkit || sudo yum install -y nvidia-container-toolkit

    elif has pacman; then
      if   has yay;  then yay  -S --noconfirm nvidia-container-toolkit
      elif has paru; then paru -S --noconfirm nvidia-container-toolkit
      else warn "AUR helper not found — install nvidia-container-toolkit from AUR manually."; fi
    fi
    success "NVIDIA Container Toolkit installed."
  fi

  info "Setting NVIDIA as the default Docker runtime..."
  sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
  sudo systemctl restart docker
  sleep 3

  info "Configuring containerd NVIDIA runtime (for k3s nodes inside k3d)..."
  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>/dev/null || true

  if docker run --rm --gpus all nvidia/cuda:12.3.1-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    success "Docker GPU smoke-test passed"
  else
    warn "Docker GPU smoke-test skipped (image may need pulling). Continuing..."
  fi

  K3D_GPU_FLAGS=("--gpus=all")
}
