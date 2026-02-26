#!/usr/bin/env bash
# =============================================================================
#  gpu-amd.sh — AMD ROCm installation (Linux)
# =============================================================================

install_rocm() {
  step "AMD ROCm"

  if has rocm-smi; then
    success "ROCm already installed: $(rocm-smi --version 2>/dev/null || echo 'version unknown')"
    return
  fi

  info "Installing ROCm..."
  if has apt-get; then
    curl -fsSL https://repo.radeon.com/amdgpu-install/latest/ubuntu/jammy/amdgpu-install_6.1.60100-1_all.deb \
      -o /tmp/amdgpu-install.deb
    sudo apt-get install -y /tmp/amdgpu-install.deb
    sudo amdgpu-install -y --usecase=rocm
    rm -f /tmp/amdgpu-install.deb
  elif has dnf; then
    sudo dnf install -y \
      https://repo.radeon.com/amdgpu-install/latest/rhel/9.2/amdgpu-install-6.1.60100-1.el9.noarch.rpm
    sudo amdgpu-install -y --usecase=rocm
  else
    warn "Auto ROCm install only supported on Ubuntu/RHEL — install manually:"
    warn "  https://rocm.docs.amd.com/en/latest/deploy/linux/quick_start.html"
    return
  fi

  sudo usermod -aG render,video "$USER"
  success "ROCm installed. A logout/login may be needed for group membership."
}
