#!/usr/bin/env bash
# =============================================================================
#  gpu-amd.sh — AMD ROCm installation (Linux)
# =============================================================================

ROCM_REPO_BASE="https://repo.radeon.com/amdgpu-install/latest"

_detect_ubuntu_codename() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  elif has lsb_release; then
    lsb_release -cs
  fi
}

_detect_rhel_version() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_ID:-}"
  fi
}

# Scrape the directory listing to find the .deb or .rpm filename
_find_package_name() {
  local dir_url="$1" ext="$2"
  curl -fsSL "$dir_url" | grep -oP "amdgpu-install[^\"<>]*\\.${ext}" | head -1
}

install_rocm() {
  step "AMD ROCm"

  if has rocm-smi; then
    success "ROCm already installed: $(rocm-smi --version 2>/dev/null || echo 'version unknown')"
    return
  fi

  info "Installing ROCm..."
  if has apt-get; then
    local codename
    codename="$(_detect_ubuntu_codename)"
    [[ -z "$codename" ]] && error "Could not detect Ubuntu codename for ROCm repo."

    local deb_dir="${ROCM_REPO_BASE}/ubuntu/${codename}/"
    local deb_name
    deb_name="$(_find_package_name "$deb_dir" "deb")"
    [[ -z "$deb_name" ]] && error "No amdgpu-install .deb found at ${deb_dir}"

    info "Downloading ${deb_name} ..."
    curl -fsSL "${deb_dir}${deb_name}" -o /tmp/amdgpu-install.deb
    sudo apt-get install -y /tmp/amdgpu-install.deb
    sudo amdgpu-install -y --usecase=rocm
    rm -f /tmp/amdgpu-install.deb

  elif has dnf || has yum; then
    local rhel_ver
    rhel_ver="$(_detect_rhel_version)"
    [[ -z "$rhel_ver" ]] && error "Could not detect RHEL/CentOS version for ROCm repo."

    local el_major="${rhel_ver%%.*}"
    local rpm_dir="${ROCM_REPO_BASE}/rhel/${rhel_ver}/"
    local rpm_name
    rpm_name="$(_find_package_name "$rpm_dir" "rpm")"

    # Fallback: try major-version-only path (e.g. /rhel/9/)
    if [[ -z "$rpm_name" ]]; then
      rpm_dir="${ROCM_REPO_BASE}/rhel/${el_major}/"
      rpm_name="$(_find_package_name "$rpm_dir" "rpm")"
    fi
    [[ -z "$rpm_name" ]] && error "No amdgpu-install .rpm found at ${ROCM_REPO_BASE}/rhel/${rhel_ver}/ (also tried ${el_major}/)"

    info "Installing ${rpm_name} ..."
    if has dnf; then sudo dnf install -y "${rpm_dir}${rpm_name}"
    else              sudo yum install -y "${rpm_dir}${rpm_name}"; fi
    sudo amdgpu-install -y --usecase=rocm

  else
    warn "Auto ROCm install only supported on Ubuntu/RHEL/CentOS — install manually:"
    warn "  https://rocm.docs.amd.com/en/latest/deploy/linux/quick_start.html"
    return
  fi

  sudo usermod -aG render,video "$USER"
  success "ROCm installed. A logout/login may be needed for group membership."
}
