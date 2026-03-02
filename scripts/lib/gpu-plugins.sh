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
    *)      info "No GPU device plugin needed." ;;
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
  step "Deploying NVIDIA k8s Device Plugin"
  if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null 2>&1; then
    success "NVIDIA device plugin already present."
    return
  fi

  info "Downloading and applying NVIDIA device plugin DaemonSet..."
  _apply_remote_manifest "$NVIDIA_DEVICE_PLUGIN_URL" "NVIDIA device plugin" || error "Failed to deploy NVIDIA device plugin"
  kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
    -n kube-system --timeout=120s \
    || warn "Rollout timed out — plugin may still be pulling. Check: kubectl get pods -n kube-system"
  success "NVIDIA device plugin deployed."
}

_deploy_amd_plugin() {
  step "Deploying AMD GPU k8s Device Plugin"
  if kubectl get daemonset -n kube-system amdgpu-device-plugin &>/dev/null 2>&1; then
    success "AMD device plugin already present."
    return
  fi

  info "Downloading and applying AMD GPU device plugin DaemonSet..."
  if _apply_remote_manifest "$AMD_DEVICE_PLUGIN_URL" "AMD device plugin"; then
    kubectl rollout status daemonset/amdgpu-device-plugin -n kube-system --timeout=120s 2>/dev/null || true
    success "AMD device plugin deployed."
  else
    # Fallback: try master if pinned release missing
    warn "Pinned AMD plugin ${AMD_DEVICE_PLUGIN_VERSION} failed; trying master..."
    _apply_remote_manifest "https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml" "AMD device plugin (master)" || warn "AMD device plugin deploy failed."
  fi
}

# ── Node-level GPU verification ─────────────────────────────────────────────
verify_gpu() {
  [[ "$GPU_VENDOR" != "nvidia" && "$GPU_VENDOR" != "amd" ]] && return

  step "Verifying GPU on Node"
  info "Waiting up to 90s for GPU to appear as allocatable resource..."

  for i in {1..18}; do
    RAW=$(kubectl get nodes -o json 2>/dev/null \
      | grep -o '"[^"]*gpu[^"]*"\s*:\s*"[^"]*"' \
      | sed 's/"//g; s/\s*:\s*/=/g' | head -5 \
      2>/dev/null || echo "")
    if [[ -n "$RAW" ]]; then
      success "GPU visible on node: $RAW"
      return
    fi
    sleep 5; printf "."
  done
  echo ""
  warn "GPU resource not yet visible. The device plugin may still be initialising."
  warn "Re-check with: kubectl describe node | grep -A5 Allocatable"
}
