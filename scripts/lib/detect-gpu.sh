#!/usr/bin/env bash
# =============================================================================
#  detect-gpu.sh — Identify GPU vendor and driver state
# =============================================================================

detect_gpu() {
  step "GPU Detection"

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      GPU_VENDOR="apple_silicon"
      warn "Apple Silicon GPU detected — k3d/Docker does not support Metal GPU passthrough."
    else
      warn "Intel Mac — no GPU passthrough available in k3d on macOS."
    fi
    info "Kubernetes will be installed in CPU-only mode. For GPU workloads, use a Linux host."
    return
  fi

  if has nvidia-smi && nvidia-smi &>/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    success "Driver    : $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
    return
  fi

  if has lspci; then
    if lspci 2>/dev/null | grep -qi "NVIDIA"; then
      GPU_VENDOR="nvidia"
      NVIDIA_DRIVER_OK=false
      warn "NVIDIA GPU detected via lspci — drivers not yet installed."
      return
    fi
    if lspci 2>/dev/null | grep -qi "AMD.*VGA\|Advanced Micro Devices.*VGA\|Radeon"; then
      GPU_VENDOR="amd"
      success "AMD GPU: $(lspci 2>/dev/null | grep -i 'Radeon\|AMD.*VGA' | head -1)"
      return
    fi
  fi

  if [[ -d /proc/driver/nvidia ]]; then
    GPU_VENDOR="nvidia"; NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU detected via /proc/driver."
    return
  fi

  warn "No discrete GPU found — CPU-only mode."
}
