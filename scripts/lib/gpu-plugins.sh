#!/usr/bin/env bash
# =============================================================================
#  gpu-plugins.sh — k8s GPU device plugin deployment + node verification
# =============================================================================

readonly NVIDIA_DEVICE_PLUGIN_VERSION="v0.14.5"
readonly NVIDIA_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
# Pin to release tag when available; fallback to master in _deploy_amd_plugin if URL fails
readonly AMD_DEVICE_PLUGIN_VERSION="v1.0.0"
readonly AMD_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/${AMD_DEVICE_PLUGIN_VERSION}/k8s-ds-amdgpu-dp.yaml"

deploy_gpu_device_plugin() {
  case "$GPU_VENDOR" in
    nvidia) _deploy_nvidia_plugin ;;
    amd)    _deploy_amd_plugin ;;
    *)      log "No GPU device plugin needed." ;;
  esac
}

# Download manifest to temp file and apply (avoids apply -f remote URL; enables future checksum verification)
_apply_remote_manifest() {
  local url="$1" label="$2"
  local tmp_yml
  tmp_yml="$(mktemp)"
  trap "rm -f '$tmp_yml'" RETURN
  retry 3 5 curl -fsSL "$CURL_SECURE" "$url" -o "$tmp_yml" || { rm -f "$tmp_yml"; return 1; }
  [[ -s "$tmp_yml" ]] || { warn "Downloaded $label manifest is empty"; rm -f "$tmp_yml"; return 1; }
  kubectl apply -f "$tmp_yml"
}

_deploy_nvidia_plugin() {
  log "Deploying NVIDIA k8s device plugin"
  if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null 2>&1; then
    success "GPU acceleration enabled."
    return
  fi

  log "Downloading and applying NVIDIA device plugin DaemonSet..."
  _apply_remote_manifest "$NVIDIA_DEVICE_PLUGIN_URL" "NVIDIA device plugin" || error "Failed to enable GPU acceleration."
  kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
    -n kube-system --timeout=120s \
    || warn "GPU setup still in progress — it may take a moment to finish."
  success "GPU acceleration enabled."
}

_deploy_amd_plugin() {
  log "Deploying AMD GPU k8s device plugin"
  if kubectl get daemonset -n kube-system amdgpu-device-plugin &>/dev/null 2>&1; then
    success "GPU acceleration enabled."
    return
  fi

  log "Downloading and applying AMD GPU device plugin DaemonSet..."
  if _apply_remote_manifest "$AMD_DEVICE_PLUGIN_URL" "AMD device plugin"; then
    kubectl rollout status daemonset/amdgpu-device-plugin -n kube-system --timeout=120s 2>/dev/null || true
    success "GPU acceleration enabled."
  else
    log "Pinned AMD plugin ${AMD_DEVICE_PLUGIN_VERSION} failed; trying master..."
    _apply_remote_manifest "https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml" "AMD device plugin (master)" || warn "GPU acceleration setup may need manual attention."
  fi
}

# ── Node-level GPU verification ─────────────────────────────────────────────
verify_gpu() {
  [[ "$GPU_VENDOR" != "nvidia" && "$GPU_VENDOR" != "amd" ]] && return

  log "Verifying GPU on node..."

  for i in {1..18}; do
    RAW=$(kubectl get nodes -o json 2>/dev/null \
      | grep -o '"[^"]*gpu[^"]*"\s*:\s*"[^"]*"' \
      | sed 's/"//g; s/\s*:\s*/=/g' | head -5 \
      2>/dev/null || echo "")
    if [[ -n "$RAW" ]]; then
      success "GPU verified and available."
      log "GPU resource on node: $RAW"
      return
    fi
    sleep 5
  done
  warn "GPU may still be initializing. Check back shortly."
}
