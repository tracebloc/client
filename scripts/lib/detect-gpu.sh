#!/usr/bin/env bash
# =============================================================================
#  detect-gpu.sh — Identify GPU vendor and driver state
# =============================================================================

detect_gpu() {
  log "GPU detection starting — OS=$OS ARCH=$ARCH"

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      GPU_VENDOR="apple_silicon"
      echo ""
      warn "Apple Silicon detected."
      info "GPU acceleration is not yet available on macOS."
      info "Your environment will run in CPU mode."
      echo ""
      hint "For GPU-accelerated model training,"
      hint "deploy tracebloc on a Linux machine with NVIDIA GPUs."
    else
      warn "Intel Mac detected."
      info "Your environment will run in CPU mode."
    fi
    return
  fi

  if has nvidia-smi && nvidia-smi &>/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    log "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
    return
  fi

  if has lspci; then
    if lspci 2>/dev/null | grep -qi "NVIDIA"; then
      GPU_VENDOR="nvidia"
      NVIDIA_DRIVER_OK=false
      warn "NVIDIA GPU detected — drivers not yet installed."
      return
    fi
    if lspci 2>/dev/null | grep -qi "AMD.*VGA\|Advanced Micro Devices.*VGA\|Radeon"; then
      GPU_VENDOR="amd"
      success "AMD GPU detected: $(lspci 2>/dev/null | grep -i 'Radeon\|AMD.*VGA' | head -1)"
      return
    fi
  fi

  if [[ -d /proc/driver/nvidia ]]; then
    GPU_VENDOR="nvidia"; NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU detected."
    return
  fi

  info "No GPU detected. Your environment will run in CPU mode."
}
