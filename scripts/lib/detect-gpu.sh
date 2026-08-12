#!/usr/bin/env bash
# =============================================================================
#  detect-gpu.sh — Identify GPU vendor and driver state
# =============================================================================

detect_gpu() {
  log "GPU detection starting — OS=$OS ARCH=$ARCH"

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      GPU_VENDOR="apple_silicon"
    fi
    echo ""
    warn "GPU training isn't supported on macOS yet — this machine will run in CPU mode."
    hint "For GPU-accelerated training, deploy on a Linux machine with NVIDIA GPUs."
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
    # Capture ONCE, then match the captured value. `lspci | grep -qi` lets grep
    # close the pipe on its first hit; lspci takes SIGPIPE and pipefail makes the
    # pipeline 141, which the `if` reads as "no such GPU" — a CPU-mode cluster on
    # a GPU host. lspci streams device-per-line, so an NVIDIA/AMD card early in
    # the enumeration is exactly the case that loses the race (backend#1778).
    local lspci_out amd_line
    lspci_out="$(lspci 2>/dev/null || true)"
    if grep -qi "NVIDIA" <<<"$lspci_out"; then
      GPU_VENDOR="nvidia"
      NVIDIA_DRIVER_OK=false
      warn "NVIDIA GPU detected — drivers not yet installed."
      return
    fi
    if grep -qi "AMD.*VGA\|Advanced Micro Devices.*VGA\|Radeon" <<<"$lspci_out"; then
      GPU_VENDOR="amd"
      amd_line="$(grep -i 'Radeon\|AMD.*VGA' <<<"$lspci_out" || true)"
      success "AMD GPU detected: ${amd_line%%$'\n'*}"
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
